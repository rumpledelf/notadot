import Foundation

func selfTest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notadot-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AppError.message("FAIL: " + message) }; print("PASS: " + message)
    }
    func wait(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); usleep(20000) }
    }
    let store = try Store(directory: directory)
    store.settings.title = "Housekeeping"
    store.session.threadID = "test-thread"; store.session.messages = [Message(role: "you", text: "Keep this across a reboot")]
    try store.saveSettings(); try store.saveSession()
    let restored = try Store(directory: directory)
    try check(restored.settings.title == "Housekeeping" && restored.session.threadID == "test-thread" && restored.session.messages.count == 1, "Settings and session survive a fresh Store")
    var replies: [Message] = []
    Transcript.item(["id": "progress", "phase": "commentary", "text": ""], turn: "turn-1", messages: &replies)
    Transcript.delta(["itemId": "progress", "delta": "Got it."], turn: "turn-1", messages: &replies)
    try check(Transcript.visible(replies).first?.phase == "commentary", "Progress is identified while a turn is working")
    replies.append(Message(role: "tool", text: "notadot"))
    Transcript.item(["id": "final", "phase": "final_answer", "text": ""], turn: "turn-1", messages: &replies)
    Transcript.delta(["itemId": "final", "delta": "Understood."], turn: "turn-1", messages: &replies)
    Transcript.item(["id": "final", "phase": "final_answer", "text": "Understood."], turn: "turn-1", messages: &replies)
    Transcript.item(["id": "final", "phase": "final_answer", "text": "Understood."], turn: "turn-1", messages: &replies)
    try check(Transcript.visible(replies).filter { $0.role == "assistant" }.map(\.text) == ["Understood."] && replies.filter { $0.itemID == "final" }.count == 1, "Commentary/tool/final replay displays one finished reply without duplicating completed items")
    let persistedReplies = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(replies))
    try check(Transcript.visible(persistedReplies).filter { $0.role == "assistant" }.count == 1 && persistedReplies.count == 3, "Phase and turn metadata survive reload without deleting the underlying history")
    replies.append(Message(role: "assistant", text: "A stable partial result", phase: "partial_answer", turnID: "turn-1"))
    replies.append(Message(role: "assistant", text: "Still working on the next turn", phase: "commentary", turnID: "turn-2"))
    try check(Transcript.visible(replies).contains { $0.phase == "partial_answer" } && Transcript.visible(replies).contains { $0.turnID == "turn-2" }, "Stable partial answers and progress from another turn are preserved")
    var oldReplies = [Message(role: "assistant", text: "Old progress", itemID: "old-progress"), Message(role: "assistant", text: "Old final", itemID: "old-final")]
    Transcript.item(["id": "old-progress", "phase": "commentary", "text": "Old progress"], turn: "old-turn", messages: &oldReplies)
    Transcript.item(["id": "old-final", "phase": "final_answer", "text": "Old final"], turn: "old-turn", messages: &oldReplies)
    try check(Transcript.visible(oldReplies).map(\.text) == ["Old final"], "Resumed Codex items repair phase metadata in older saved conversations")
    try check(Store.codexPath("/usr/bin/true") == "/usr/bin/true" && Store.codexPath(directory.path + "/missing") == nil, "A configured Codex path is used as given, and a missing one is reported")
    restored.settings.codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path; try restored.saveSettings()
    let migrated = try Store(directory: directory)
    try check(migrated.settings.codex.isEmpty, "The old saved default Codex path becomes automatic")
    let runtimes = RuntimeManager(directory: directory); defer { runtimes.stopAll() }
    let tools = NativeTools(store: restored, runtimes: runtimes); tools.interactive = false
    _ = try tools.perform(["action": "notes_append", "text": "Remember the exact port."])
    let notes = try tools.perform(["action": "notes_read"])
    try check((notes.first?["text"] as? String)?.contains("Remember the exact port.") == true, "Native notes persist to disk")
    let projectFolder = directory.appendingPathComponent("job-project"); let child = projectFolder.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let jobProject = Project(name: "Jobs", path: projectFolder.path, port: 0, start: "")
    try check(try Jobs.folder(child.path, projects: [jobProject]) == child.path, "Jobs accept subfolders of configured projects")
    let sibling = directory.appendingPathComponent("job-project-other"); try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    do { _ = try Jobs.folder(sibling.path, projects: [jobProject]); throw AppError.message("FAIL: sibling accepted") }
    catch AppError.message(let text) where text.contains("configured") { print("PASS: Jobs reject sibling paths") }
    let escape = child.appendingPathComponent("escape"); try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sibling)
    do { _ = try Jobs.folder(escape.path, projects: [jobProject]); throw AppError.message("FAIL: symlink escape accepted") }
    catch AppError.message(let text) where text.contains("configured") { print("PASS: Job folders cannot escape through symlinks") }
    let jobs = Jobs(store: restored, codex: Codex())
    var job = Job(title: "Fixture", folder: projectFolder.path, model: "fixture-model", task: "Local test")
    job.threadID = "job-thread"; restored.jobs = [job]
    try check(jobs.event("item/agentMessage/delta", ["threadId": "another-thread", "itemId": "reply", "delta": "wrong"]) == false, "Job routing ignores unrelated threads")
    _ = jobs.event("item/agentMessage/delta", ["threadId": "job-thread", "itemId": "reply", "delta": "Private job result"])
    _ = jobs.event("turn/completed", ["threadId": "job-thread", "turn": ["status": "completed"]])
    let disk = try Store(directory: directory)
    try check(disk.jobs.first?.latestReply == "Private job result" && disk.jobs.first?.state == .done && !disk.session.messages.contains(where: { $0.text.contains("Private job result") }), "Job results survive reload without entering the housekeeper transcript")
    try jobs.archive(job.id)
    try check(try Store(directory: directory).jobs.first?.archived == true, "Finished jobs can be archived persistently")
    let fractional = try PlannerDates.parse("2026-10-22T15:00:00.123+11:00")
    let ordinary = try PlannerDates.parse("2026-10-22T04:00:00Z")
    try check(abs(fractional.timeIntervalSince(ordinary) - 0.123) < 0.01, "Reminder timestamps preserve timezone offsets and fractional seconds")
    _ = try PlannerDates.parse("2026-10-22")
    do { _ = try PlannerDates.parse("2026-02-30"); throw AppError.message("FAIL: invalid calendar date accepted") }
    catch AppError.message(let text) where text.contains("ISO") { print("PASS: Invalid reminder dates are rejected") }
    do { _ = try PlannerDates.due(["title": "Undated"]); throw AppError.message("FAIL: undated alert accepted") }
    catch AppError.message(let text) where text.contains("due date") { print("PASS: Reminder alerts require a real due date") }
    do { _ = try PlannerDates.range(["start": "2026-10-23", "end": "2026-10-22"], required: true); throw AppError.message("FAIL: reversed range accepted") }
    catch AppError.message(let text) where text.contains("end must") { print("PASS: Reversed calendar ranges are rejected") }
    var plannerDenied = false
    tools.performAsync(["action": "reminder_lists"]) { result in if case .failure = result { plannerDenied = true } }
    try check(plannerDenied, "Noninteractive tests cannot access real reminders or calendar accounts")
    let eventDraft = CalendarDraft(title: "Review", start: ordinary, end: ordinary.addingTimeInterval(3600), calendarID: "fixture", calendarName: "Work", source: "iCloud", location: "Desk", notes: "Keep these notes")
    let changedDraft = try eventDraft.updating(["title": "Project review", "location": "Office"])
    try check(changedDraft.title == "Project review" && changedDraft.notes == eventDraft.notes && changedDraft.start == eventDraft.start && eventDraft.location == "Desk", "Calendar drafts preserve unchanged fields and leave the original untouched")
    try check(changedDraft.preview.contains("Project review") && changedDraft.preview.contains("Office") && changedDraft.preview.contains("iCloud"), "Calendar confirmations describe the proposed title, calendar, and location")
    for action in CalendarWriter.actions {
        var written = false
        do {
            try CalendarWriteGate.commit(confirm: { false }, revalidate: {}, write: { written = true })
            throw AppError.message("FAIL: declined calendar write ran")
        } catch AppError.message(let text) where text.contains("User declined") { }
        try check(!written, "Declining \(action) prevents the database operation")
    }
    var writeCount = 0
    try CalendarWriteGate.commit(confirm: { true }, revalidate: {}, write: { writeCount += 1 })
    try check(writeCount == 1, "Calendar approval authorizes exactly one operation")
    do {
        try CalendarWriteGate.commit(confirm: { true }, revalidate: { throw AppError.message("Event changed during review") }, write: { writeCount += 1 })
        throw AppError.message("FAIL: stale calendar approval accepted")
    } catch AppError.message(let text) where text.contains("changed during review") { }
    try check(writeCount == 1, "An event changed during review cannot be written using stale approval")
    do { try CalendarWriter.validate(["action": "calendar_delete", "event": "series-id"]); throw AppError.message("FAIL: ambiguous occurrence accepted") }
    catch AppError.message(let text) where text.contains("occurrence") { print("PASS: Calendar deletions require the exact occurrence, not just a series ID") }
    do { _ = try eventDraft.updating(["end": "2026-10-21T00:00:00Z"]); throw AppError.message("FAIL: invalid event range accepted") }
    catch AppError.message(let text) where text.contains("end must") { print("PASS: Calendar writes reject reversed times") }
    do { _ = try eventDraft.updating(["allDay": true]); throw AppError.message("FAIL: non-midnight all-day event accepted") }
    catch AppError.message(let text) where text.contains("midnight") { print("PASS: All-day events require valid midnight boundaries") }
    var calendarDenied = false
    tools.performAsync(["action": "calendar_add", "title": "Do not save", "start": "2026-10-22T15:00:00+11:00", "end": "2026-10-22T16:00:00+11:00"]) { result in if case .failure = result { calendarDenied = true } }
    try check(calendarDenied, "Noninteractive checks cannot create real calendar events")
    do { _ = try tools.perform(["action": "clipboard_read"]); throw AppError.message("FAIL: disabled clipboard was accessible") }
    catch AppError.message(let text) where text.contains("Not allowed") { print("PASS: Clipboard needs permission") }
    do { _ = try tools.perform(["action": "screen_view"]); throw AppError.message("FAIL: disabled screen was accessible") }
    catch AppError.message(let text) where text.contains("Not allowed") { print("PASS: Screen viewing needs permission") }
    // Test-only ports never become project configuration. Production never picks a port.
    guard let port = (49152...49250).first(where: { !RuntimeManager.portOccupied($0) && !RuntimeManager.portOccupied($0 + 1) }) else { throw AppError.message("No adjacent test ports available") }
    let server = "/usr/bin/perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(LocalAddr=>\"127.0.0.1\",LocalPort=>shift,Listen=>5,ReuseAddr=>1) or die $!; sleep 60' {port}"
    let project = Project(name: "Fixture", path: directory.path, port: port, start: server)
    try runtimes.start(project); wait(0.5)
    let initialStatus = runtimes.status(project).text
    if !initialStatus.hasPrefix("Running") {
        print("Runtime state:", initialStatus)
        print((try? String(contentsOf: directory.appendingPathComponent("runtime-\(project.id).log"))) ?? "No log")
    }
    try check(initialStatus.hasPrefix("Running"), "Runtime starts on its configured port")
    let other = Project(name: "Conflict", path: directory.path, port: port, start: server)
    do { try runtimes.start(other); throw AppError.message("FAIL: occupied port accepted") }
    catch AppError.message(let text) where text.contains("occupied") { print("PASS: Occupied port is refused") }
    do { try runtimes.stop(other); throw AppError.message("FAIL: unmanaged listener stopped") }
    catch AppError.message(let text) where text.contains("does not own") { print("PASS: Unmanaged process is protected") }
    try runtimes.stop(project); wait(0.5)
    try check(!RuntimeManager.portOccupied(port), "Stop terminates the owned runtime group")
    let wrong = Project(name: "Wrong port", path: directory.path, port: port, start: server.replacingOccurrences(of: "{port}", with: String(port + 1)) + " # {port}")
    if !RuntimeManager.portOccupied(port + 1) {
        try runtimes.start(wrong); wait(0.5)
        try check(runtimes.status(wrong).text.contains("different port"), "Wrong-port runtime is stopped instead of adopted")
        wait(0.5); try check(!RuntimeManager.portOccupied(port + 1), "Wrong-port listener is cleaned up")
    }
    var invalid = restored.settings; invalid.projects = [project, other]
    invalid.codex = "/usr/bin/true" // Any executable; this check is about ports, not where Codex is installed.
    do { try restored.validate(invalid); throw AppError.message("FAIL: duplicate ports accepted") }
    catch AppError.message(let text) where text.contains("already runs on port") { print("PASS: Duplicate fixed ports are rejected") }
    // Settings from earlier builds have no url and a root key; they must still load.
    let legacy = #"{"title":"Old","root":"/tmp","projects":[{"id":"a","name":"fern","path":"/tmp","port":8000,"start":"php -S localhost:{port}","stop":""}]}"#
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
    try check(decoded.projects.first?.url == "" && decoded.projects.first?.openURL?.absoluteString == "http://localhost:8000/", "Older settings load, and Open defaults to the port")
    var linkA = Project(name: "fern layout", path: directory.path, port: 8000, start: "", url: "http://localhost:8000/tools/layout/")
    let linkB = Project(name: "fern draw", path: directory.path, port: 8000, start: "", url: "http://localhost:8000/tools/draw/")
    let fernServer = Project(name: "fern", path: directory.path, port: 8000, start: "cd fern-landing && php artisan serve --port={port}")
    try Store.validate(projects: [linkA, linkB, fernServer])
    print("PASS: Link-only projects can share a port with the server project")
    linkA.start = "npm run dev"
    do { try Store.validate(projects: [linkA]); throw AppError.message("FAIL: command without {port} accepted") }
    catch AppError.message(let text) where text.contains("{port}") { print("PASS: A Runs command must say where the port goes") }

    let fern = directory.appendingPathComponent("fern"); try FileManager.default.createDirectory(at: fern, withIntermediateDirectories: true)
    try "To run it, start the fern-landing server:\n\n```bash\ncd fern-landing\nphp artisan serve\n```\nThen open http://localhost:8000/tools/layout/\n".write(to: fern.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    let guess = RunDetector.guess(fern)
    try check(guess.command == "cd fern-landing && php artisan serve --port={port}" && guess.port == 8000, "README run command keeps its cd and gains {port}: \(guess.command)")
    let vite = directory.appendingPathComponent("vite"); try FileManager.default.createDirectory(at: vite, withIntermediateDirectories: true)
    try #"{"scripts":{"dev":"vite","build":"vite build"}}"#.write(to: vite.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try check(RunDetector.guess(vite).command == "npm run dev -- --port {port} --strictPort", "package.json Vite script gets a strict port")
    let photo = directory.appendingPathComponent("photo"); try FileManager.default.createDirectory(at: photo.appendingPathComponent("public"), withIntermediateDirectories: true)
    try "```\ncd /Users/someone/Sites/photo\nphp -S 127.0.0.1:8001 -t public\n```\n".write(to: photo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    let photoGuess = RunDetector.guess(photo)
    try check(photoGuess.command == "php -S 127.0.0.1:{port} -t public" && photoGuess.port == 8001, "An absolute cd from another computer is dropped, and 127.0.0.1 ports are read: \(photoGuess.command)")
    do { try RuntimeManager.checkFolders(Project(name: "Photo", path: photo.path, port: 8001, start: "cd /nowhere/photo && php -S 127.0.0.1:{port}")); throw AppError.message("FAIL: missing cd folder accepted") }
    catch AppError.message(let text) where text.contains("doesn't exist on this Mac") { print("PASS: A cd into a missing folder is refused before starting") }
    try check(RunDetector.relativeCD("~/Sites/fern/fern-landing", folderName: "fern") == "fern-landing" && RunDetector.relativeCD("/Users/x/Sites/photo", folderName: "photo") == nil && RunDetector.relativeCD("/elsewhere/thing", folderName: "photo") == nil, "Absolute cds are rewritten relative to the chosen folder")
    print("All native self-tests passed.")
}
