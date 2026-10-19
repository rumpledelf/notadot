import AppKit
import CoreGraphics

final class NativeTools {
    let store: Store
    let runtimes: RuntimeManager
    var changed: (() -> Void)?
    init(store: Store, runtimes: RuntimeManager) { self.store = store; self.runtimes = runtimes }
    static var definitions: [[String: Any]] {
        let actions = ["notes_read", "notes_append", "clipboard_read", "clipboard_write", "screen_view", "projects_list", "project_start", "project_stop"]
        return [["type": "function", "name": "notadot", "description": "Use the local Notadot app's persistent notes, clipboard, screenshot, and fixed-port project controls. Notes survive compaction and reboot. Screen/clipboard access require app settings and user confirmation. Project names must exactly match configured projects.", "inputSchema": ["type": "object", "properties": ["action": ["type": "string", "enum": actions], "text": ["type": "string"], "project": ["type": "string"]], "required": ["action"], "additionalProperties": false]]]
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
            guard store.settings.clipboardEnabled else { throw AppError.message("Clipboard tools are disabled in Settings.") }
            try confirm(action == "clipboard_read" ? "Read your clipboard?" : "Replace your clipboard?", action == "clipboard_read" ? "The clipboard text will be sent to Codex." : String(text.prefix(1500)))
            if action == "clipboard_read" { result = NSPasteboard.general.string(forType: .string) ?? "Clipboard has no text." }
            else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); result = "Clipboard updated." }
        case "screen_view":
            guard store.settings.screenEnabled else { throw AppError.message("Screen viewing is disabled in Settings.") }
            try confirm("Share your screen with Codex?", "A screenshot of the main display will be sent to the model for this request.")
            return [["type": "inputImage", "imageUrl": try screenshot()]]
        case "projects_list":
            let rows: [[String: Any]] = store.settings.projects.map { ["name": $0.name, "path": $0.path, "port": $0.port, "status": runtimes.status($0)] }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]); result = String(data: data, encoding: .utf8) ?? "[]"
        case "project_start", "project_stop":
            guard let p = store.settings.projects.first(where: { $0.name == args["project"] as? String }) else { throw AppError.message("Unknown project. Use projects_list first.") }
            if action == "project_start" { try runtimes.start(p) } else { try runtimes.stop(p) }
            result = runtimes.status(p); changed?()
        default: throw AppError.message("Unknown native action: \(action)")
        }
        return [["type": "inputText", "text": result]]
    }
    func confirm(_ title: String, _ detail: String) throws {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Allow once"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { throw AppError.message("User declined.") }
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
