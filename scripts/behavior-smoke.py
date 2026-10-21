"""Opt-in LIVE test using the housekeeper's configured model and Codex sign-in.

No native actions run: tool requests fail this test and are denied. Uses one
ephemeral thread with synthetic notes, never the user's actual app conversation.
"""
import collections
import json
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time


root = pathlib.Path(__file__).resolve().parents[1]
binary = root / "build/Notadot.app/Contents/MacOS/Notadot"
contract = json.loads(subprocess.check_output([str(binary), "--assistant-contract"], text=True))
settings = json.loads((pathlib.Path.home() / "Library/Application Support/Notadot/settings.json").read_text())
codex = settings.get("codex") or shutil.which("codex") or str(pathlib.Path.home() / ".local/bin/codex")
messages = queue.Queue()
pending = collections.deque()
counter = 0

with tempfile.TemporaryDirectory(prefix="notadot-behavior-") as directory:
    process = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, cwd=directory)
    def read():
        for line in process.stdout:
            messages.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()

    def write(value):
        process.stdin.write(json.dumps(value) + "\n")
        process.stdin.flush()

    def call(method, params):
        global counter
        counter += 1
        write({"id": counter, "method": method, "params": params})
        deadline = time.monotonic() + 60
        while True:
            item = messages.get(timeout=max(0.1, deadline - time.monotonic()))
            if item.get("id") == counter and "method" not in item:
                if "error" in item:
                    raise RuntimeError(item["error"])
                return item["result"]
            pending.append(item)
            if time.monotonic() >= deadline:
                raise TimeoutError(method)

    try:
        call("initialize", {"clientInfo": {"name": "notadot_behavior_test", "version": "0.1.0"},
                            "capabilities": {"experimentalApi": True}})
        write({"method": "initialized", "params": {}})
        account = call("account/read", {"refreshToken": False}).get("account") or {}
        if account.get("type") != "chatgpt":
            raise RuntimeError("Live behavior checks require an existing ChatGPT-plan Codex sign-in.")
        params = {"cwd": directory, "runtimeWorkspaceRoots": [directory], "ephemeral": True,
                  "developerInstructions": contract["instructions"], "dynamicTools": contract["tools"],
                  "sandbox": "read-only", "approvalPolicy": "never",
                  "config": {"apps._default.enabled": False, "features.multi_agent": False}}
        if settings.get("model"):
            params["model"] = settings["model"]
        thread = call("thread/start", params)["thread"]["id"]
        print("Model:", settings.get("model") or "Codex default", flush=True)
        cases = ["ok still in testing mode with this new app",
                 "well there's a bug straight away, you answered twice",
                 "there's nothing going on to report progress", "thanks"]
        for index, text in enumerate(cases):
            inputs = [{"type": "text", "text": text}]
            if index == 0:
                inputs.insert(0, {"type": "text", "text": contract["notes"]})
            call("turn/start", {"threadId": thread, "input": inputs})
            replies = []
            attempts = []
            deadline = time.monotonic() + 90
            while True:
                item = pending.popleft() if pending else messages.get(timeout=max(0.1, deadline - time.monotonic()))
                method = item.get("method", "")
                p = item.get("params", {})
                if "method" in item and "id" in item:
                    attempts.append(method)
                    write({"id": item["id"], "error": {"code": -32601, "message": "Native actions are blocked in this behavior test."}})
                if p.get("threadId") != thread:
                    continue
                value = p.get("item", {})
                if method == "item/started" and value.get("type") not in {"userMessage", "agentMessage", "reasoning", "contextCompaction"}:
                    attempts.append(value.get("type"))
                if method == "item/completed" and value.get("type") == "agentMessage":
                    replies.append(value)
                if method == "turn/completed":
                    assert p["turn"]["status"] == "completed", p["turn"].get("error")
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError("Acknowledgement turn")
            assert not attempts, f"Unexpected tool activity for {text!r}: {attempts}"
            assert len(replies) == 1 and replies[0].get("phase") == "final_answer", replies
            print(f"PASS: {text!r}: one final reply, no commentary, no tools", flush=True)
            print("  " + replies[0]["text"], flush=True)
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
