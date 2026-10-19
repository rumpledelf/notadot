# Notadot

A small native macOS home for a long-running Codex housekeeping session. Built for this Intel Mac and macOS Big Sur 11; no Electron, browser server, JavaScript runtime, or third-party Swift packages.

## Run

```sh
bash scripts/build.sh
open build/Notadot.app
```

The app uses the installed `codex app-server` and its existing Codex sign-in and configuration. It does not extract credentials or call the Responses API itself. If needed, sign in using `codex login` in your usual terminal first. The executable path is configurable; the initial path is `~/.local/bin/codex`. Tested with Codex CLI 0.162.1.

The build script uses the installed Command Line Tools compiler and SDK, targets Intel/macOS 11, and ad-hoc signs a local `.app`. Keep the app at a stable path for macOS Screen Recording permissions. A development signing identity may change between builds and macOS may require granting screen access again.

## Using it

- Settings (`⌘,`): window name, project root, notes file, external notes editor, Codex path/model, native permissions, and configured projects.
- Notes (`⌘N`): built-in Markdown text editor with Save and Reload. Changes on disk are checked before saving to protect assistant edits. “Open notes externally” uses the configured macOS application name, such as `TextEdit`, or the system default.
- Send (`⌘Return`): start a turn. While working it becomes Steer, which adds your instruction to the current turn. Stop interrupts the current turn.
- Compact: ask the actual Codex harness to compact its context. Codex also retains its normal automatic context management. Notes and the displayed transcript remain on disk.
- Share screen: attach a screenshot of the main display to the next message. Stop discards an unsent attachment. Enable screen viewing in Settings first, then grant Notadot access in System Preferences → Security & Privacy → Privacy → Screen Recording. macOS may require quitting and reopening the app.
- Paste clipboard: a user-initiated paste into the message composer. Separately, the assistant's clipboard tools must be enabled in Settings and ask before each read or write.
- The assistant's `notadot` tool can read/append notes, list/start/stop configured projects, read/write clipboard text, and request a screenshot. Screen captures require per-request confirmation. There is no continuous screen recording.
- Codex command/file/permission approvals appear in the app. Unknown protocol requests return an explicit error instead of hanging or silently approving.

Closing the main window keeps the app, active turn, and project runtimes alive. Click the Dock icon to reopen it. Quitting stops app-owned work and runtimes; reopen to resume the saved conversation. Restart recovery restores the conversation, notes, and configuration; project runtimes stay stopped until you start them. The app does not run while the computer is off or launch automatically at login.

## Projects and exact ports

Each configured project has a name, absolute folder path, port, start command, and optional stop command. No ports are assigned automatically. The start command must contain `{port}`; `PORT` is also set in its environment.

For Vite, for example:

```sh
npm run dev -- --port {port} --strictPort
```

Use the equivalent strict binding option for other servers. Notadot refuses an already-occupied IPv4 or IPv6 port. It monitors the launched process group, reports running only when that group listens on the configured port, and stops it if it detects an unexpected listening port. This is supervision after launch; a command that itself selects a fallback port may briefly open it before detection. Configure strict mode in the command to prevent fallback entirely. Servers must stay in the foreground and listen within 30 seconds.

Start commands run in the configured project folder through the user's login Bash environment. Stop sends a signal to the app-owned process group and runs the optional configured stop command. It never adopts or kills an unrelated listener. Runtime logs are available from each project's Log button. Closing the window preserves runtimes; explicitly quitting stops them. A forced app crash may leave a runtime unmanaged: its occupied port is reported on reopening, and Notadot refuses to kill it based solely on a port number.

## Storage

App data lives in `~/Library/Application Support/Notadot/`:

- `settings.json`: configuration and project definitions.
- `session.json`: current thread ID and local conversation transcript, written atomically. Streamed replies are checkpointed about once per second.
- `notes.md`: default persistent memory; its path is configurable. Choosing a new nonexistent notes file copies the current notes there; choosing an existing file uses that file without overwriting it.
- `runtime-<project-id>.log`: output from each launched project.

Codex retains its own underlying session history in its usual data directory. Notadot resumes that same thread. An empty, unused thread ID is not persisted, because Codex does not save its rollout until the first turn. The visible chat renders the latest 250 messages to keep long sessions responsive; the full local transcript stays in `session.json`. Notes are separate from model context and survive compaction and computer restarts. Back them up like any other local files.

## Checks

```sh
bash scripts/build.sh
build/Notadot.app/Contents/MacOS/Notadot --self-test
python3 scripts/protocol-smoke.py
build/Notadot.app/Contents/MacOS/Notadot --ui-smoke
```

Native checks exercise disk persistence, permission defaults, runtime start/stop, occupied-port refusal, unrelated-process protection, wrong-port shutdown, and duplicate-port validation. They use temporary folders and local fixture listeners.

The protocol smoke test creates an isolated Codex home and deliberately unreachable local model provider. It checks initialization, tool registration, turn interruption, process restart, thread resume, and persisted native-tool definitions without sending a live model request. It requires Python 3 and the installed Codex binary.

The UI smoke test opens the three native windows using temporary data and saves images of those app windows under `/tmp/notadot-ui-smoke/`. It does not connect to Codex or capture other apps.

Integration reference: [official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server). Protocol fields were also checked against JSON Schemas generated by the installed Codex binary, including its experimental dynamic-tool API.
