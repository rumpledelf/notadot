import Foundation

func selfTest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notadot-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message("FAIL: " + message) }; print("PASS: " + message)
    }
    func wait(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); usleep(20000) }
    }
    let store = try Store(directory: directory)
    store.settings.title = "Housekeeping"; store.settings.root = directory.path
    store.session.threadID = "test-thread"; store.session.messages = [Message(role: "you", text: "Keep this across a reboot")]
    try store.saveSettings(); try store.saveSession()
    let restored = try Store(directory: directory)
    try check(restored.settings.title == "Housekeeping" && restored.session.threadID == "test-thread" && restored.session.messages.count == 1, "Settings and session survive a fresh Store")
    let runtimes = RuntimeManager(directory: directory); defer { runtimes.stopAll() }
    let tools = NativeTools(store: restored, runtimes: runtimes)
    _ = try tools.perform(["action": "notes_append", "text": "Remember the exact port."])
    let notes = try tools.perform(["action": "notes_read"])
    try check((notes.first?["text"] as? String)?.contains("Remember the exact port.") == true, "Native notes persist to disk")
    do { _ = try tools.perform(["action": "clipboard_read"]); throw AppError.message("FAIL: disabled clipboard was accessible") }
    catch AppError.message(let text) where text.contains("disabled") { print("PASS: Clipboard is opt-in") }
    do { _ = try tools.perform(["action": "screen_view"]); throw AppError.message("FAIL: disabled screen was accessible") }
    catch AppError.message(let text) where text.contains("disabled") { print("PASS: Screen viewing is opt-in") }
    // Test-only ports never become project configuration. Production never picks a port.
    guard let port = (49152...49250).first(where: { !RuntimeManager.portOccupied($0) && !RuntimeManager.portOccupied($0 + 1) }) else { throw AppError.message("No adjacent test ports available") }
    let server = "/usr/bin/perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(LocalAddr=>\"127.0.0.1\",LocalPort=>shift,Listen=>5,ReuseAddr=>1) or die $!; sleep 60' {port}"
    let project = Project(name: "Fixture", path: directory.path, port: port, start: server)
    try runtimes.start(project); wait(0.5)
    let initialStatus = runtimes.status(project)
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
        try check(runtimes.status(wrong).contains("unconfigured port"), "Wrong-port runtime is stopped instead of adopted")
        wait(0.5); try check(!RuntimeManager.portOccupied(port + 1), "Wrong-port listener is cleaned up")
    }
    var invalid = restored.settings; invalid.projects = [project, other]
    do { try restored.validate(invalid); throw AppError.message("FAIL: duplicate ports accepted") }
    catch AppError.message(let text) where text.contains("unique") { print("PASS: Duplicate fixed ports are rejected") }
    print("All native self-tests passed.")
}
