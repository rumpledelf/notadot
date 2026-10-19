"""No-inference compatibility check against the installed Codex app-server."""
import json
import os
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time


class Client:
    def __init__(self, home):
        env = dict(os.environ, CODEX_HOME=str(home))
        self.p = subprocess.Popen([shutil.which("codex"), "app-server"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, env=env)
        self.messages = queue.Queue()
        self.counter = 0
        def read():
            for line in self.p.stdout:
                self.messages.put(json.loads(line))
        threading.Thread(target=read, daemon=True).start()
        self.call("initialize", {"clientInfo": {"name": "notadot_test", "version": "0.1.0"},
                                 "capabilities": {"experimentalApi": True}})
        self.write({"method": "initialized", "params": {}})

    def write(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def call(self, method, params):
        self.counter += 1
        self.write({"id": self.counter, "method": method, "params": params})
        while True:
            obj = self.messages.get(timeout=30)
            if obj.get("id") == self.counter:
                if "error" in obj:
                    raise RuntimeError(obj["error"])
                return obj["result"]

    def close(self):
        self.p.terminate()
        self.p.wait(timeout=10)


with tempfile.TemporaryDirectory(prefix="notadot-protocol-") as directory:
    home = pathlib.Path(directory)
    # A deliberately unreachable loopback provider creates a persisted failed turn.
    # This exercises recovery without contacting a real model or using any tokens.
    (home / "config.toml").write_text('''model = "gpt-5.4"
model_provider = "offline_fixture"
[model_providers.offline_fixture]
name = "Offline protocol fixture"
base_url = "http://127.0.0.1:1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
''')
    client = Client(home)
    try:
        response = client.call("thread/start", {
            "cwd": str(home), "runtimeWorkspaceRoots": [str(home)],
            "dynamicTools": [{"type": "function", "name": "notadot",
                              "description": "Local app tool", "inputSchema": {
                                  "type": "object", "properties": {"action": {"type": "string"}},
                                  "required": ["action"], "additionalProperties": False}}]})
        thread = response["thread"]["id"]
        print("PASS: initialize and thread/start with native tool")
        turn = client.call("turn/start", {"threadId": thread, "input": [{"type": "text", "text": "Offline fixture"}]})
        time.sleep(0.5)
        client.call("turn/interrupt", {"threadId": thread, "turnId": turn["turn"]["id"]})
        print("PASS: offline turn starts and can be interrupted without a live model")
    finally:
        client.close()
    client = Client(home)
    try:
        response = client.call("thread/resume", {"threadId": thread, "cwd": str(home),
                              "runtimeWorkspaceRoots": [str(home)],
                              "developerInstructions": "Persistent housekeeping assistant"})
        assert response["thread"]["id"] == thread
        print("PASS: thread resumes after app-server process restart")
        records = list(home.rglob("*.jsonl"))
        assert any('notadot' in record.read_text() for record in records), "Native tool was not persisted"
        print("PASS: native tool definition persists in the Codex session")
    finally:
        client.close()
