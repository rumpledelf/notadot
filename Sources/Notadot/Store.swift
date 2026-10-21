import Foundation

struct Project: Codable {
    var id = UUID().uuidString
    var name: String
    var path: String
    var port: Int
    var start: String // Empty: a link-only project that Notadot never starts or stops.
    var stop: String = ""
    var url: String = "" // Empty: http://localhost:<port>/.
    init(name: String, path: String, port: Int, start: String, stop: String = "", url: String = "") {
        self.name = name; self.path = path; self.port = port; self.start = start; self.stop = stop; self.url = url
    }
    // Decoded field by field so settings written by older builds still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        stop = try c.decodeIfPresent(String.self, forKey: .stop) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
    var managed: Bool { !start.trimmingCharacters(in: .whitespaces).isEmpty }
    static func defaultURL(_ port: Int) -> String { port > 0 ? "http://localhost:\(port)/" : "" }
    var openURL: URL? {
        let text = url.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return URL(string: text.contains("://") ? text : "http://" + text) }
        return port > 0 ? URL(string: "http://localhost:\(port)/") : nil
    }
}
struct Settings: Codable {
    var title = "Notadot"
    var notes = ""
    var editor = "" // macOS application name; empty uses the default Markdown application.
    var codex = "" // Empty finds codex at launch, so updates and reinstalls that move it need no setting change.
    var model = ""
    var jobsModel = ""
    var screenEnabled = false
    var clipboardEnabled = false
    var projects: [Project] = []
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? d.title
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? d.notes
        editor = try c.decodeIfPresent(String.self, forKey: .editor) ?? d.editor
        codex = try c.decodeIfPresent(String.self, forKey: .codex) ?? d.codex
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        jobsModel = try c.decodeIfPresent(String.self, forKey: .jobsModel) ?? d.jobsModel
        screenEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenEnabled) ?? d.screenEnabled
        clipboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardEnabled) ?? d.clipboardEnabled
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? d.projects
    }
}
struct Message: Codable {
    var role: String
    var text: String
    var itemID: String?
}
struct Session: Codable {
    var threadID: String?
    var messages: [Message] = []
    var toolVersion: Int? // nil identifies sessions created before versioned native tools.
    var pendingJobNotes: [String]? // Short reports only; never a job transcript.
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
final class Store {
    let directory: URL
    var settings: Settings
    var session: Session
    var jobs: [Job]
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Notadot")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let settingsURL = self.directory.appendingPathComponent("settings.json")
        let sessionURL = self.directory.appendingPathComponent("session.json")
        settings = FileManager.default.fileExists(atPath: settingsURL.path) ? try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL)) : Settings()
        session = FileManager.default.fileExists(atPath: sessionURL.path) ? try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessionURL)) : Session()
        let jobsURL = self.directory.appendingPathComponent("jobs.json")
        jobs = FileManager.default.fileExists(atPath: jobsURL.path) ? try JSONDecoder().decode([Job].self, from: Data(contentsOf: jobsURL)) : []
        // Earlier builds saved this default explicitly; treat it as "find codex" so it follows reinstalls.
        if settings.codex == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path { settings.codex = "" }
        if settings.notes.isEmpty { settings.notes = self.directory.appendingPathComponent("notes.md").path }
        if !FileManager.default.fileExists(atPath: settings.notes) {
            try "# Notadot notes\n\nPersistent preferences, decisions, and loose ends live here.\n".write(toFile: settings.notes, atomically: true, encoding: .utf8)
        }
        try saveSettings()
    }
    func saveSettings() throws { try write(settings, "settings.json") }
    func saveSession() throws { try write(session, "session.json") }
    func saveJobs() throws { try write(jobs, "jobs.json") }
    private func write<T: Encodable>(_ value: T, _ filename: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
    func validate(_ s: Settings) throws {
        guard !s.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("Give the assistant a name.") }
        guard s.notes.hasPrefix("/"), FileManager.default.fileExists(atPath: URL(fileURLWithPath: s.notes).deletingLastPathComponent().path) else { throw AppError.message("Notes need an absolute path in an existing folder.") }
        guard Self.codexPath(s.codex) != nil else { throw AppError.message(s.codex.isEmpty ? "Codex was not found. Install it, or choose it." : "Codex executable was not found at that path.") }
        try Self.validate(projects: s.projects)
    }
    static func validate(projects: [Project]) throws {
        var ports = Set<Int>(); var names = Set<String>(); var ids = Set<String>()
        for p in projects {
            var isDir: ObjCBool = false
            guard !p.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppError.message("Give the project a name.") }
            guard p.path.hasPrefix("/"), FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue else { throw AppError.message("\(p.name): the folder doesn't exist.") }
            guard names.insert(p.name.lowercased()).inserted, ids.insert(p.id).inserted else { throw AppError.message("There's already a project called \(p.name).") }
            guard p.port == 0 || (1024...65535).contains(p.port) else { throw AppError.message("\(p.name): ports run from 1024 to 65535.") }
            if p.managed {
                // Only projects Notadot starts own a port; link-only projects may share one, like fern's tools.
                guard p.port > 0 else { throw AppError.message("\(p.name): a project with a Runs command needs a port.") }
                guard p.start.contains("{port}") else { throw AppError.message("\(p.name): put {port} in the Runs command where the port goes.") }
                guard ports.insert(p.port).inserted else { throw AppError.message("\(p.name): another project already runs on port \(p.port).") }
            }
            if !p.url.trimmingCharacters(in: .whitespaces).isEmpty, p.openURL == nil { throw AppError.message("\(p.name): that Open address isn't a valid URL.") }
        }
    }
    /// A configured path wins. Otherwise search the usual install locations, then the login shell's PATH,
    /// because an app opened from Finder does not inherit the terminal's PATH.
    static func codexPath(_ configured: String) -> String? {
        let fm = FileManager.default
        if !configured.isEmpty { return fm.isExecutableFile(atPath: configured) ? configured : nil }
        let home = fm.homeDirectoryForCurrentUser.path
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] where fm.isExecutableFile(atPath: dir + "/codex") { return dir + "/codex" }
        let found = RuntimeManager.command("/bin/bash", ["-lc", "command -v codex"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return found.hasPrefix("/") && fm.isExecutableFile(atPath: found) ? found : nil
    }
}
