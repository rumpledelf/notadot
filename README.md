# Notadot

A small native macOS home for a long-running Codex housekeeping session. Built for this Intel Mac and macOS Big Sur 11; no Electron, browser server, JavaScript runtime, or third-party Swift packages.

## Run

```sh
bash scripts/build.sh
open build/Notadot.app
```

The app uses the installed `codex app-server` and its existing Codex sign-in and configuration. It does not extract credentials or call the Responses API itself. If needed, sign in using `codex login` in your usual terminal first. By default Notadot finds `codex` each time it connects (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then your login shell's PATH), so updates and reinstalls need no setting change; a path entered in Settings overrides this. Codex updates often, so no particular version is required: the connected version is shown next to the token count, failed Codex calls name the protocol method, and `scripts/protocol-smoke.py` checks the parts Notadot relies on after an update without using any tokens.

The build script uses the installed Command Line Tools compiler and SDK, targets Intel/macOS 11, and ad-hoc signs a local `.app`. Keep the app at a stable path for macOS Screen Recording permissions. A development signing identity may change between builds and macOS may require granting screen access again.

## Using it

- **Chat:** one long-running Codex session. Return sends and Shift-Return adds a line; while it's working, sending steers the current turn and `⌘.` stops it. Compact asks Codex to compact its context. Screen and clipboard sharing are in the composer's **+** menu.
- **Notes:** `notes.md` works like AGENTS.md. Notadot includes it with your first message after every connect or compaction, and the assistant adds to it. **Notes** in the sidebar shows it formatted (read-only); the pencil opens it in your notes editor.
- **Settings** (`⌘,`, or the cog bottom left): name, notes editor, model (listed by the connected Codex), Codex (automatic or a chosen executable), and New Session, which archives the conversation and starts fresh. Notes carry over.
- **Permissions:** the first time the assistant wants the screen or clipboard, Notadot asks: Allow Once, Don't Allow, or Always Allow. Codex command and file approvals always ask.

Closing the main window keeps the app, active turn, and project runtimes alive. Click the Dock icon to reopen it. Quitting stops app-owned work and runtimes; reopen to resume the saved conversation. Project runtimes stay stopped until you start them.

## Projects

**Add a project** picks a folder (starting in your home folder), then suggests how it runs from its README, `package.json`, or framework files, and a free port. Each project has:

- **Runs:** a shell command run from the project folder. It may `cd` into a subfolder, for example `cd fern-landing && php artisan serve --port={port}`. It must contain `{port}`; `PORT` is also set. Leave it empty for a link-only project, such as one running on another computer: no start or stop, just open.
- **Port:** fixed. Notadot refuses an occupied port and never picks another. Projects with a Runs command need unique ports; link-only projects can share one.
- **Open:** the address the ↗ button opens, which may include a path or another host. Empty means `http://localhost:<port>/`. The ↗ button always tries, whatever the status says.

Status dots: **green**, Notadot started it and it's running; **red**, Notadot's project, stopped; **blue**, something answers that Notadot didn't start; **grey**, nothing answering. Link-only projects are checked by loading their address.

Notadot supervises what it starts: it reports running only when the process group listens on the configured port, stops it if it opens a different port, and gives up if the port doesn't open within 30 seconds. It never stops a process it didn't start. When dev servers it didn't start are running, the sidebar offers **Ask Notadot to sort these out**, which hands the list to the chat; the assistant asks before stopping anything.

## Storage

App data lives in `~/Library/Application Support/Notadot/`:

- `settings.json`: settings and projects.
- `session-<time>.json`: conversations archived by New Session.
- `session.json`: current thread ID and local conversation transcript, written atomically. Streamed replies are checkpointed about once per second.
- `notes.md`: persistent notes.
- `runtime-<project-id>.log`: output from each launched project.

Codex retains its own underlying session history in its usual data directory. Notadot resumes that same thread. An empty, unused thread ID is not persisted, because Codex does not save its rollout until the first turn. The visible chat renders the latest 250 messages to keep long sessions responsive; the full local transcript stays in `session.json`. Notes are separate from model context and survive compaction and computer restarts. Back them up like any other local files.

## Checks

```sh
bash scripts/build.sh
build/Notadot.app/Contents/MacOS/Notadot --self-test
python3 scripts/protocol-smoke.py
build/Notadot.app/Contents/MacOS/Notadot --ui-smoke
```

Native checks exercise disk persistence, permission prompts, runtime start/stop, occupied-port refusal, unrelated-process protection, wrong-port shutdown, port validation, loading older settings, and run-command detection. They use temporary folders and local fixture listeners.

The protocol smoke test creates an isolated Codex home and deliberately unreachable local model provider. It checks initialization, tool registration, turn interruption, process restart, thread resume, and persisted native-tool definitions without sending a live model request. It requires Python 3 and the installed Codex binary.

The UI smoke test opens the main window with a draft message, notes view and Settings using temporary data. It captures light mode, dark mode, and a switch back to light mode under `/tmp/notadot-ui-smoke/` (`light-`, `dark-`, and `light-again-` images). It does not connect to Codex or capture other apps.

Integration reference: [official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server). Protocol fields were also checked against JSON Schemas generated by the installed Codex binary, including its experimental dynamic-tool API.
