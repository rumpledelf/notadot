import Foundation

struct Project: Codable {
    var id = UUID().uuidString
    var name: String
    var path: String
    var port: Int
    var start: String
    var stop: String = ""
}
struct Settings: Codable {
    var title = "Notadot"
    var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sites").path
    var notes = ""
    var editor = "" // macOS application name; empty uses the default Markdown application.
    var codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
    var model = ""
    var screenEnabled = false
    var clipboardEnabled = false
    var projects: [Project] = []
}
struct Message: Codable {
    var role: String
    var text: String
    var itemID: String?
}
struct Session: Codable {
    var threadID: String?
    var messages: [Message] = []
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
final class Store {
    let directory: URL
    var settings: Settings
    var session: Session
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Notadot")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let settingsURL = self.directory.appendingPathComponent("settings.json")
        let sessionURL = self.directory.appendingPathComponent("session.json")
        settings = FileManager.default.fileExists(atPath: settingsURL.path) ? try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL)) : Settings()
        session = FileManager.default.fileExists(atPath: sessionURL.path) ? try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessionURL)) : Session()
        if settings.notes.isEmpty { settings.notes = self.directory.appendingPathComponent("notes.md").path }
        if !FileManager.default.fileExists(atPath: settings.notes) {
            try "# Notadot notes\n\nPersistent preferences, decisions, and loose ends live here.\n".write(toFile: settings.notes, atomically: true, encoding: .utf8)
        }
        try saveSettings()
    }
    func saveSettings() throws { try write(settings, "settings.json") }
    func saveSession() throws { try write(session, "session.json") }
    private func write<T: Encodable>(_ value: T, _ filename: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
    func validate(_ s: Settings) throws {
        guard !s.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("Give the window a name.") }
        var isDir: ObjCBool = false
        guard s.root.hasPrefix("/"), FileManager.default.fileExists(atPath: s.root, isDirectory: &isDir), isDir.boolValue else { throw AppError.message("Project root must be an existing absolute folder path.") }
        guard s.notes.hasPrefix("/"), FileManager.default.fileExists(atPath: URL(fileURLWithPath: s.notes).deletingLastPathComponent().path) else { throw AppError.message("Notes need an absolute path in an existing folder.") }
        guard FileManager.default.isExecutableFile(atPath: s.codex) else { throw AppError.message("Codex executable was not found at that path.") }
        var ports = Set<Int>(); var names = Set<String>(); var ids = Set<String>()
        for p in s.projects {
            guard !p.name.isEmpty, !p.start.isEmpty, p.path.hasPrefix("/"), FileManager.default.fileExists(atPath: p.path), (1024...65535).contains(p.port) else { throw AppError.message("Each project needs a name, existing absolute path, start command, and port from 1024 to 65535.") }
            guard ports.insert(p.port).inserted, names.insert(p.name.lowercased()).inserted, ids.insert(p.id).inserted else { throw AppError.message("Project names, IDs, and ports must be unique.") }
        }
    }
}
