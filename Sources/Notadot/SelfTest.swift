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
