# Brief: handing jobs to a stronger model

Notadot (this repo) is a native macOS app (AppKit, macOS 11, Intel, no third-party packages) hosting one long-running Codex housekeeping session. It's my own version of OpenAI's dots. The housekeeper runs on a cheap model (Luna) and stays open for weeks. It's fine for small jobs, but it can't do real development work. A dot hands bigger work off and reports back, and Notadot should do the same: start a separate Codex session on a stronger model (Sol), let it work, and keep track of it.

## What to build

- **Settings:** a "Jobs model", chosen from the models the connected Codex lists (`model/list`), like the existing model setting. Don't hard-code model names.
- **Native tool actions** on the existing `notadot` tool (`NativeTools.swift`):
  - `job_start`: a title, a project folder (one of my projects, or a path under it), and the task text. The text can simply be "Read BRIEF-x.md in this folder and do it."
  - `job_list`: each job's title, folder, status, and when it started.
  - `job_result`: a job's latest reply.
  - `job_message`: send a follow-up to a job.
  
  Starting a job always asks me first (same Allow Once / Don't Allow prompt style as the screen and clipboard), showing the title, folder, model, and task.
- **Running jobs:** each job is its own thread on the same app-server connection (`thread/start` with the Jobs model and the job's folder as `cwd`). Jobs do not get Notadot's native tools, so they can't start more jobs or touch reminders and email. Command and file approvals for a job ask me as usual, with the job's title in the dialog so I know which one is asking.
- **Routing:** `event(_:_:)` in `App.swift` currently ignores events for other threads. Route them to the right job instead.
- **Sidebar:** a Jobs section, styled like the project rows: a status dot (working, waiting for me, done, failed) and the title. Clicking a job shows its conversation in the main pane, with the composer sending to that job, so I can answer it directly (for example when a brief says "stop and show me screenshots"). A clear way back to the housekeeper chat.
- **Reporting back:** when a job's turn finishes, post a macOS notification and put a short note in the housekeeper chat ("Job 'Visual polish' finished / is waiting for you"), so the housekeeper can summarise it or chase it up. Don't start a housekeeper turn automatically for this.
- **Persistence:** jobs and their thread IDs survive quitting and reopening, and resume like the main session. Finished jobs can be archived out of the sidebar.
- **Cost:** a job's full transcript never goes into the housekeeper's context; only the short note does, plus whatever the housekeeper explicitly reads with `job_result`.

Update the assistant instructions in `App.swift` so the housekeeper knows to offer a job for anything beyond quick housekeeping, and update `README.md`. Extend `--self-test` and `scripts/protocol-smoke.py` where possible without using tokens. Match the existing code style. Commit in small steps.
