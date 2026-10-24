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
- Progress messages are marked **Working** while a turn runs, then collapse when its final answer arrives. Stable partial answers remain visible. The original items and their phases remain saved; reconnecting fills in phase metadata for older conversations. This applies to housekeeper and job chats.
- Simple acknowledgements and temporary status updates require one final reply with no progress or tools. Loaded notes are reference material, not a request to rewrite memory on every message. Durable notes still work for remembered preferences, project decisions, and actual work.
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

## Jobs

Choose a **Jobs model** in Settings from the connected Codex model list. Ask the housekeeper to delegate substantial development work: it calls `job_start` with a title, folder, and task (for example, “Read BRIEF-x.md and implement it”). Every start asks **Allow Once / Don't Allow**, showing the complete task, folder, and model. The folder must be a configured project or a subfolder; symlinks cannot escape that boundary.

Jobs run as separate Codex threads on the same connection. They do not receive the Notadot native tool, so cannot start more jobs or use its personal-data actions. Command, file, and permission approvals still ask, with the job title in the dialog. The Jobs section shows working, waiting, done, and failed states. Select a job to read its conversation, send or steer it, or stop it. **Housekeeper chat** switches back; each conversation keeps its draft. Finished/stopped jobs can be archived.

When a job finishes or asks for input, Notadot posts a macOS notification and a short status note in the housekeeper chat. Click the notification to open that job. Only the short note enters the housekeeper's context; `job_result` explicitly retrieves a job's latest reply. There is no automatic housekeeper inference turn. Jobs and their transcripts live in `jobs.json`; reopening resumes their threads without automatically rerunning interrupted work.

**Existing sessions:** this installed Codex version persists native-tool definitions from thread creation and cannot replace them on resume. Notadot shows a notice when a saved session predates its current tools. Use **Settings → New Session** to enable new actions; the old transcript is archived and notes carry over. It never silently discards a conversation to upgrade tools.

## Reminders and calendar · testing checkpoint

The housekeeper has EventKit actions for reminders and calendars. macOS requests Reminders or Calendar permission on first use, independently. Calendar reads use `calendar_lists` and `calendar_events`; writes use `calendar_add`, `calendar_update`, and `calendar_delete`. Every write requires a native **Allow Once / Don’t Allow** confirmation showing the calendar, title, dates, timezone, location, and notes. Edits show before/after values; deletion shows the exact event. Reminder lists can be read by ID or unique name, incomplete reminders can be filtered by due range, and reads return at most 100 items (30 by default).

New reminders require a due date and get a real EventKit alarm at that instant. Notadot selects a writable iCloud reminder list, preferring your default when it is in iCloud, and refuses to silently create a local-only reminder. You can choose an iCloud list explicitly. Sync and iPhone delivery still depend on iCloud being enabled on both devices and on your notification settings. Date-only inputs mean local midnight; give an explicit time and timezone for timed alerts. Calendar queries require a start/end range of at most a year; keep it narrow. To edit or delete, use the ID and original `occurrence` timestamp from the event listing. Repeating events are changed for that occurrence only, never the entire series. Calendar changes are rechecked after confirmation; if the event moved or changed during review, the operation is refused and must be reviewed again. There is no Always Allow setting for calendar writes. Notes, location, all-day status, and target calendar can be changed; event fields omitted from an edit are preserved. All-day events need midnight boundaries, with an exclusive end date.

After upgrading an existing session, use **Settings → New Session** to register the expanded native tool. Try “List my reminder lists,” then a dated test reminder with an exact time, then list and complete it. Check that it arrives in Reminders on your iPhone. Ask for tomorrow's calendar events to test Calendar permission separately. Permission denial is reported in the conversation; access can be re-enabled in System Preferences → Security & Privacy → Privacy.

This is the Part A testing checkpoint from `BRIEF-reminders-checkins.md`. Email and proactive check-ins are deferred until that test passes. This build does not schedule unattended inference or missed check-ins. Automated tests validate dates, edits, and confirmation gating—including denial and stale approvals—without reading or changing real reminder/calendar accounts.

## Storage

App data lives in `~/Library/Application Support/Notadot/`:

- `settings.json`: settings and projects.
- `session-<time>.json`: conversations archived by New Session.
- `session.json`: current thread ID and local conversation transcript, written atomically. Streamed replies are checkpointed about once per second.
- `jobs.json`: delegated jobs, their model, folder, status, thread ID, and separate transcripts.
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

`python3 scripts/behavior-smoke.py` is a separate **live model check**. It uses the housekeeper model from app settings and the existing ChatGPT-plan Codex sign-in, so it uses model tokens. It sends four short acknowledgement/status messages in an ephemeral thread with synthetic notes and the app's actual instructions/tool definitions. Native tool requests are blocked and fail the test. Each turn must produce exactly one final answer, no commentary, and no tool calls. It never opens the real housekeeper conversation or reads the user's notes.

Integration reference: [official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server). Protocol fields were also checked against JSON Schemas generated by the installed Codex binary, including its experimental dynamic-tool API.
