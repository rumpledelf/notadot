import AppKit

final class FlippedView: NSView { override var isFlipped: Bool { true } }

func field(_ value: String = "", placeholder: String = "") -> NSTextField {
    let f = NSTextField(string: value); f.placeholderString = placeholder; return f
}
func button(_ title: String, _ target: AnyObject, _ selector: Selector) -> NSButton { NSButton(title: title, target: target, action: selector) }
func row(_ views: NSView...) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 8; s.alignment = .centerY; return s
}
func column(_ views: [NSView]) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .vertical; s.spacing = 12; s.alignment = .leading; return s
}
func label(_ text: String, bold: Bool = false) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: text); f.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 12); return f
}
func pin(_ view: NSView, in parent: NSView, inset: CGFloat = 16) {
    view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view)
    NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    let store: Store
    var saved: (() -> Void)?
    let window: NSWindow
    let titleField: NSTextField, root: NSTextField, notes: NSTextField, editor: NSTextField, codex: NSTextField, model: NSTextField
    let screen = NSButton(checkboxWithTitle: "Allow screen viewing (asks before each capture)", target: nil, action: nil)
    let clipboard = NSButton(checkboxWithTitle: "Allow clipboard tools (asks before each use)", target: nil, action: nil)
    let projectPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let projectName = field(), projectPath = field(), projectPort = field(), projectStart = field(), projectStop = field()
    var projects: [Project]
    var selected = -1
    init(store: Store) {
        self.store = store; let s = store.settings; projects = s.projects
        titleField = field(s.title); root = field(s.root); notes = field(s.notes); editor = field(s.editor, placeholder: "Default Markdown app, or e.g. TextEdit")
        codex = field(s.codex); model = field(s.model, placeholder: "Empty uses your Codex default")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Notadot Settings"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentMinSize = NSSize(width: 680, height: 600)
        screen.state = s.screenEnabled ? .on : .off; clipboard.state = s.clipboardEnabled ? .on : .off
        projectPicker.target = self; projectPicker.action = #selector(selectProject)
        let pairs: [(String, NSTextField)] = [("Window name", titleField), ("Project root", root), ("Persistent notes file", notes), ("External notes editor", editor), ("Codex executable", codex), ("Model", model)]
        var views: [NSView] = [label("Your assistant, your settings", bold: true)]
        for (name, f) in pairs { views.append(label(name)); views.append(f) }
        views += [screen, clipboard, label("Projects · fixed ports only", bold: true), row(projectPicker, button("Add", self, #selector(addProject)), button("Remove", self, #selector(removeProject)))]
        for (name, f) in [("Name", projectName), ("Folder", projectPath), ("Port", projectPort), ("Start command · use {port}", projectStart), ("Optional stop command", projectStop)] {
            views.append(label(name)); views.append(f)
        }
        views.append(label("Example: npm run dev -- --port {port} --strictPort\nPORT is also set. The app stops a runtime if it detects another listening port. Changes take effect after Save; reconnect applies Codex settings."))
        let content = column(views)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = doc
        content.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(content)
        NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20), content.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20), content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20), content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20)])
        for view in views where view is NSTextField && (view as? NSTextField)?.isEditable == true { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let body = column([scroll, row(button("Save", self, #selector(save)), button("Cancel", self, #selector(cancel)))])
        pin(body, in: window.contentView!, inset: 12)
        scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true
        refreshPicker(); window.center()
    }
    func show() { window.makeKeyAndOrderFront(nil) }
    private func commitProject() {
        guard selected >= 0 && selected < projects.count else { return }
        projects[selected].name = projectName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        projects[selected].path = (projectPath.stringValue as NSString).expandingTildeInPath
        projects[selected].port = Int(projectPort.stringValue) ?? 0
        projects[selected].start = projectStart.stringValue; projects[selected].stop = projectStop.stringValue
    }
    private func refreshPicker() {
        projectPicker.removeAllItems(); projectPicker.addItems(withTitles: projects.map { $0.name.isEmpty ? "Untitled project" : $0.name })
        selected = projects.isEmpty ? -1 : min(max(selected, 0), projects.count - 1)
        if selected >= 0 { projectPicker.selectItem(at: selected) }
        loadProject()
    }
    private func loadProject() {
        let enabled = selected >= 0
        [projectName, projectPath, projectPort, projectStart, projectStop].forEach { $0.isEnabled = enabled }
        guard enabled else { [projectName, projectPath, projectPort, projectStart, projectStop].forEach { $0.stringValue = "" }; return }
        let p = projects[selected]; projectName.stringValue = p.name; projectPath.stringValue = p.path; projectPort.stringValue = String(p.port); projectStart.stringValue = p.start; projectStop.stringValue = p.stop
    }
    @objc private func selectProject() { commitProject(); selected = projectPicker.indexOfSelectedItem; loadProject() }
    @objc private func addProject() {
        commitProject(); projects.append(Project(name: "New project", path: root.stringValue, port: 0, start: "npm run dev -- --port {port} --strictPort")); selected = projects.count - 1; refreshPicker()
    }
    @objc private func removeProject() { guard selected >= 0 else { return }; projects.remove(at: selected); selected = -1; refreshPicker() }
    @objc private func cancel() { window.close() }
    @objc private func save() {
        commitProject()
        var s = store.settings
        s.title = titleField.stringValue; s.root = (root.stringValue as NSString).expandingTildeInPath; s.notes = (notes.stringValue as NSString).expandingTildeInPath
        s.editor = editor.stringValue; s.codex = (codex.stringValue as NSString).expandingTildeInPath; s.model = model.stringValue
        s.screenEnabled = screen.state == .on; s.clipboardEnabled = clipboard.state == .on; s.projects = projects
        do {
            try store.validate(s)
            for p in s.projects where !p.start.contains("{port}") { throw AppError.message("\(p.name)'s start command must contain {port}.") }
            if !FileManager.default.fileExists(atPath: s.notes) {
                let existing = try String(contentsOfFile: store.settings.notes, encoding: .utf8)
                try existing.write(toFile: s.notes, atomically: true, encoding: .utf8)
            }
            let old = store.settings; store.settings = s
            do { try store.saveSettings() } catch { store.settings = old; throw error }
            saved?(); window.close()
        } catch { let alert = NSAlert(error: error); alert.runModal() }
    }
}

final class NotesWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let text = NSTextView()
    let path: String
    private var original: String
    init(path: String) throws {
        self.path = path; original = try String(contentsOfFile: path, encoding: .utf8)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(); window.title = "Persistent notes"; window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 450)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text
        text.string = original; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular); text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
        let stack = column([label(path), scroll, row(button("Save", self, #selector(save)), button("Reload", self, #selector(reload)))])
        pin(stack, in: window.contentView!); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true; window.center()
    }
    @objc private func reload() {
        do { original = try String(contentsOfFile: path, encoding: .utf8); text.string = original } catch { NSAlert(error: error).runModal() }
    }
    @objc private func save() { if saveContents() { window.close() } }
    private func saveContents() -> Bool {
        do {
            guard try String(contentsOfFile: path, encoding: .utf8) == original else { throw AppError.message("The notes changed on disk. Copy your edits, then Reload to avoid overwriting the assistant's changes.") }
            try text.string.write(toFile: path, atomically: true, encoding: .utf8); original = text.string; return true
        } catch { NSAlert(error: error).runModal(); return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard text.string != original else { return true }
        let alert = NSAlert(); alert.messageText = "Save your notes before closing?"
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        return result == .alertFirstButtonReturn ? saveContents() : result == .alertSecondButtonReturn
    }
}
