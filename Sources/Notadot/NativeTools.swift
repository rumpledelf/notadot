import AppKit
import CoreGraphics

final class NativeTools {
    let store: Store
    let runtimes: RuntimeManager
    var changed: (() -> Void)?
    var interactive = true // The self-test runs without dialogs.
    var jobAction: (([String: Any], @escaping (Result<[[String: Any]], Error>) -> Void) -> Void)?
    static let version = 1
    init(store: Store, runtimes: RuntimeManager) { self.store = store; self.runtimes = runtimes }
    static var definitions: [[String: Any]] {
        let actions = ["notes_read", "notes_append", "clipboard_read", "clipboard_write", "screen_view", "projects_list", "project_start", "project_stop", "job_start", "job_list", "job_result", "job_message"]
        return [["type": "function", "name": "notadot", "description": "Local persistent notes, clipboard, screen, and fixed-port projects. Delegate substantial work using job_start(title, folder, task), which always asks the user before starting. job_list lists IDs/status, job_result(job) reads the latest reply, job_message(job, text) follows up. Jobs use the selected Jobs model; no full transcript is automatically added to your context.", "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": actions], "text": ["type": "string"], "project": ["type": "string"], "title": ["type": "string"], "folder": ["type": "string"], "task": ["type": "string"], "job": ["type": "string"]], "required": ["action"], "additionalProperties": false]]]
    }
    func performAsync(_ args: [String: Any], completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        if (args["action"] as? String ?? "").hasPrefix("job_") {
            guard let action = jobAction else { completion(.failure(AppError.message("Jobs are unavailable."))); return }
            action(args, completion); return
        }
        do { completion(.success(try perform(args))) } catch { completion(.failure(error)) }
    }
    func perform(_ args: [String: Any]) throws -> [[String: Any]] {
        let action = args["action"] as? String ?? ""
        let text = args["text"] as? String ?? ""
        var result = ""
        switch action {
        case "notes_read": result = try String(contentsOfFile: store.settings.notes, encoding: .utf8)
        case "notes_append":
            guard !text.isEmpty else { throw AppError.message("Provide text to append.") }
            let old = try String(contentsOfFile: store.settings.notes, encoding: .utf8)
            try (old + "\n" + text + "\n").write(toFile: store.settings.notes, atomically: true, encoding: .utf8)
            result = "Notes saved."
        case "clipboard_read", "clipboard_write":
            try allow(.clipboard, action == "clipboard_read" ? "Let Codex read your clipboard?" : "Let Codex replace your clipboard?", action == "clipboard_read" ? "The clipboard text is sent to Codex." : String(text.prefix(1500)))
            if action == "clipboard_read" { result = NSPasteboard.general.string(forType: .string) ?? "Clipboard has no text." }
            else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); result = "Clipboard updated." }
        case "screen_view":
            try allow(.screen, "Let Codex see your screen?", "A screenshot of the main display is sent to the model for this request.")
            return [["type": "inputImage", "imageUrl": try screenshot()]]
        case "projects_list":
            let rows: [[String: Any]] = store.settings.projects.map { ["name": $0.name, "path": $0.path, "port": $0.port, "runs": $0.start, "open": $0.openURL?.absoluteString ?? "", "status": runtimes.status($0).text] }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]); result = String(data: data, encoding: .utf8) ?? "[]"
        case "project_start", "project_stop":
            guard let p = store.settings.projects.first(where: { $0.name == args["project"] as? String }) else { throw AppError.message("Unknown project. Use projects_list first.") }
            if action == "project_start" { try runtimes.start(p) } else { try runtimes.stop(p) }
            result = runtimes.status(p).text; changed?()
        default: throw AppError.message("Unknown native action: \(action)")
        }
        return [["type": "inputText", "text": result]]
    }
    enum Permission { case screen, clipboard }
    /// Asks the first time, offering "Always allow". Once always-allowed, it no longer asks.
    func allow(_ kind: Permission, _ title: String, _ detail: String) throws {
        let always = kind == .screen ? store.settings.screenEnabled : store.settings.clipboardEnabled
        if always { return }
        guard interactive else { throw AppError.message("Not allowed yet: the user hasn't been asked.") }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Allow Once"); alert.addButton(withTitle: "Don't Allow"); alert.addButton(withTitle: "Always Allow")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return
        case .alertThirdButtonReturn:
            if kind == .screen { store.settings.screenEnabled = true } else { store.settings.clipboardEnabled = true }
            try? store.saveSettings()
        default: throw AppError.message("User declined.")
        }
    }
    func screenshot() throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw AppError.message("Allow Notadot in System Preferences → Security & Privacy → Privacy → Screen Recording, then quit and reopen the app.")
        }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw AppError.message("Screen capture failed.") }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}
