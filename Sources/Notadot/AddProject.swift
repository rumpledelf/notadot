import AppKit

/// A best guess at how a folder runs, from its README first, then package.json and framework files.
/// It is only a suggestion: the user edits it before anything starts.
struct RunGuess { var command = ""; var port: Int?; var source = "" }

enum RunDetector {
    static func guess(_ folder: URL) -> RunGuess {
        var guess = RunGuess()
        let fm = FileManager.default
        let readme = (try? fm.contentsOfDirectory(atPath: folder.path))?.first { $0.lowercased().hasPrefix("readme") }
        let readmeText = readme.flatMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) } ?? ""
        let scripts = packageScripts(folder)
        if let command = readmeCommand(readmeText, folderName: folder.lastPathComponent) {
            guess.command = command; guess.source = "From \(readme!)"
        } else if let name = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }) {
            guess.command = name == "start" ? "npm start" : "npm run \(name)"; guess.source = "From package.json"
        } else if fm.fileExists(atPath: folder.appendingPathComponent("artisan").path) {
            guess.command = "php artisan serve"; guess.source = "Laravel project"
        } else if fm.fileExists(atPath: folder.appendingPathComponent("manage.py").path) {
            guess.command = "python3 manage.py runserver"; guess.source = "Django project"
        }
        if !guess.command.isEmpty { guess.command = withPort(guess.command, scripts: scripts) }
        if let match = readmeText.range(of: "(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0):[0-9]{4,5}", options: .regularExpression) {
            guess.port = Int(readmeText[match].split(separator: ":").last ?? "")
        }
        return guess
    }
    static func packageScripts(_ folder: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json["scripts"] as? [String: String] ?? [:]
    }
    /// The first command in a code block or inline code that looks like it starts a server, keeping a
    /// preceding `cd` from the same block so subfolder setups like fern's survive.
    static func readmeCommand(_ text: String, folderName: String) -> String? {
        let starter = try! NSRegularExpression(pattern: "^(?:\\$ )?((?:npm|pnpm|yarn|bun) (?:run )?(?:dev|start|serve)\\b.*|php artisan serve.*|php -S .*|python3? -m http\\.server.*|python3? manage\\.py runserver.*|(?:bundle exec )?rails s(?:erver)?\\b.*|hugo server.*|flask run.*|uvicorn .*)$")
        var cd: String?
        var inBlock = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inBlock.toggle(); cd = nil; continue }
            let candidates = inBlock ? [line] : inlineCode(line)
            for candidate in candidates {
                if candidate.hasPrefix("cd ") { cd = relativeCD(String(candidate.dropFirst(3)), folderName: folderName); continue }
                let ns = candidate as NSString
                if let m = starter.firstMatch(in: candidate, range: NSRange(location: 0, length: ns.length)) {
                    let command = ns.substring(with: m.range(at: 1))
                    return cd.map { "cd \($0) && \(command)" } ?? command
                }
            }
        }
        return nil
    }
    /// A relative cd (fern's `cd fern-landing`) is kept. An absolute or ~ one was written on some computer
    /// where the project lived elsewhere: whatever follows the project folder's name becomes relative
    /// (`~/Sites/fern/fern-landing` → `fern-landing`), and a cd to the project itself is dropped.
    static func relativeCD(_ raw: String, folderName: String) -> String? {
        let target = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        guard target.hasPrefix("/") || target.hasPrefix("~") else { return target.isEmpty || target == "." ? nil : target }
        let parts = target.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: folderName) else { return nil }
        let rest = parts[(index + 1)...].joined(separator: "/")
        return rest.isEmpty ? nil : rest
    }
    private static func inlineCode(_ line: String) -> [String] {
        let parts = line.components(separatedBy: "`")
        return stride(from: 1, to: parts.count, by: 2).map { parts[$0].trimmingCharacters(in: .whitespaces) }
    }
    /// Put {port} where each tool expects it, adding strict-port flags where the tool has one.
    static func withPort(_ command: String, scripts: [String: String]) -> String {
        if command.contains("{port}") { return command }
        let last = command.components(separatedBy: "&& ").last ?? command
        let lead = String(command.dropLast(last.count))
        func digits(_ s: String, _ replacement: String) -> String? {
            s.range(of: "[0-9]{4,5}", options: .regularExpression).map { s.replacingCharacters(in: $0, with: replacement) }
        }
        let adapted: String
        if last.hasPrefix("npm run ") || last.hasPrefix("pnpm ") || last.hasPrefix("yarn ") || last.hasPrefix("bun ") || last == "npm start" {
            let name = last.components(separatedBy: " ").last ?? ""
            let script = scripts[name] ?? ""
            if script.contains("vite") { adapted = last + " -- --port {port} --strictPort" }
            else if script.contains("next") { adapted = last + " -- -p {port}" }
            else { adapted = "PORT={port} " + last }
        } else if last.hasPrefix("php artisan serve") { adapted = last + " --port={port}" }
        else if last.hasPrefix("php -S") { adapted = digits(last, "{port}") ?? last.replacingOccurrences(of: "php -S ", with: "php -S localhost:{port} ") }
        else if last.contains("http.server") || last.contains("runserver") { adapted = digits(last, "{port}") ?? last + " {port}" }
        else if last.hasPrefix("rails") || last.hasPrefix("bundle exec rails") { adapted = last + " -p {port}" }
        else if last.hasPrefix("hugo server") || last.hasPrefix("uvicorn") || last.hasPrefix("flask run") { adapted = last + " --port {port}" }
        else { adapted = "PORT={port} " + last }
        return lead + adapted
    }
    /// The README's port when it's free and unclaimed, else the first free one from 5173 up.
    static func suggestPort(_ preferred: Int?, taken: Set<Int>) -> Int {
        if let p = preferred, (1024...65535).contains(p), !taken.contains(p), !RuntimeManager.portOccupied(p) { return p }
        return (5173...5999).first { !taken.contains($0) && !RuntimeManager.portOccupied($0) } ?? 5173
    }
}

final class AddProjectSheet: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    private let folder: URL
    private let name: NSTextField, runs: NSTextField, port: NSTextField, open: NSTextField
    private let error = label("")
    private var shownPort = 0
    var add: ((Project) throws -> Void)?

    init(folder: URL, existing: [Project]) {
        self.folder = folder
        let guess = RunDetector.guess(folder)
        let suggested = RunDetector.suggestPort(guess.port, taken: Set(existing.filter(\.managed).map(\.port)))
        name = field(folder.lastPathComponent)
        runs = field(guess.command, placeholder: "Leave empty for a link-only project")
        runs.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        port = field(String(suggested)); port.widthAnchor.constraint(equalToConstant: 70).isActive = true
        shownPort = suggested
        open = field(Project.defaultURL(suggested), placeholder: "http://…")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        port.delegate = self
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shownPath = folder.path.hasPrefix(home) ? "~" + folder.path.dropFirst(home.count) : folder.path
        let portNote = guess.port.map { $0 == suggested ? "From the README" : "Free. The README's \($0) is taken." } ?? "Free"
        let runNote = guess.source.isEmpty ? "Runs in the project folder. Use cd for a subfolder, and {port} for the port." : guess.source + ". Runs in the project folder; use cd for a subfolder."
        let grid = NSGridView(views: [
            [right("Folder"), label(String(shownPath))],
            [right("Name"), name],
            [right("Runs"), column([runs, note(runNote)])],
            [right("Port"), row(port, note(portNote))],
            [right("Open"), column([open, note("Follows the port unless you change it. Can point at another computer.")])],
        ])
        grid.rowSpacing = 10; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for f in [name, runs, open] { f.widthAnchor.constraint(equalToConstant: 370).isActive = true }
        let cancel = button("Cancel", self, #selector(cancelSheet)); cancel.keyEquivalent = "\u{1b}"
        let addButton = button("Add Project", self, #selector(confirm)); addButton.keyEquivalent = "\r"
        let gap = NSView(); gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = row(gap, cancel, addButton)
        error.textColor = .systemRed
        let filler = NSView(); filler.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = column([label("Add project", bold: true), grid, error, filler, buttons])
        pin(stack, in: window.contentView!, inset: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func right(_ text: String) -> NSTextField { let l = label(text); l.alignment = .right; return l }
    /// Open follows the port while it still holds the default address for the previous port.
    func controlTextDidChange(_ obj: Notification) {
        let newPort = Int(port.stringValue) ?? 0
        if open.stringValue == Project.defaultURL(shownPort) { open.stringValue = Project.defaultURL(newPort) }
        shownPort = newPort
    }
    private func note(_ text: String) -> NSTextField { let l = label(text); l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11); return l }
    @objc private func cancelSheet() { window.sheetParent?.endSheet(window) }
    @objc private func confirm() {
        let project = Project(name: name.stringValue.trimmingCharacters(in: .whitespaces), path: folder.path, port: Int(port.stringValue) ?? 0,
                              start: runs.stringValue.trimmingCharacters(in: .whitespaces), url: open.stringValue.trimmingCharacters(in: .whitespaces))
        do { try add?(project); window.sheetParent?.endSheet(window) } catch { self.error.stringValue = error.localizedDescription }
    }
}
