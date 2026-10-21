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
    let window: NSWindow
    var saved: ((_ codexChanged: Bool) -> Void)?
    var newSession: (() -> Void)?
    private let name: NSTextField
    private let editor = NSPopUpButton(), model = NSPopUpButton(), jobsModel = NSPopUpButton(), codex = NSPopUpButton()
    private let codexNote = label(""), error = label("")
    private var codexChoice: String
    static let editors: [(name: String, bundle: String)] = [("BBEdit", "com.barebones.bbedit"), ("Visual Studio Code", "com.microsoft.VSCode"), ("Sublime Text", "com.sublimetext.4"), ("Zed", "dev.zed.Zed"), ("Nova", "com.panic.Nova"), ("CotEditor", "com.coteditor.CotEditor"), ("Typora", "abnerworks.Typora"), ("Obsidian", "md.obsidian"), ("MacDown", "com.uranusjr.macdown")]

    init(store: Store, models: (@escaping ([(id: String, name: String)]) -> Void) -> Void) {
        self.store = store; let s = store.settings; codexChoice = s.codex
        name = field(s.title)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 375), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"; window.isReleasedWhenClosed = false; window.delegate = self

        // Notes editor: installed editors by name, plus whatever was chosen before.
        editor.addItem(withTitle: "Default app for Markdown"); editor.lastItem?.representedObject = ""
        var editorNames = ["TextEdit"] + Self.editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }.map(\.name)
        if !s.editor.isEmpty && !editorNames.contains(s.editor) { editorNames.append(s.editor) }
        for n in editorNames { editor.addItem(withTitle: n); editor.lastItem?.representedObject = n }
        editor.menu?.addItem(.separator()); editor.addItem(withTitle: "Choose App…"); editor.lastItem?.representedObject = "choose"
        editor.selectItem(at: max(0, editor.indexOfItem(withRepresentedObject: s.editor)))
        editor.target = self; editor.action = #selector(editorPicked)

        // Model: the connected Codex lists what's available; until then just the current choice.
        model.addItem(withTitle: "Codex default"); model.lastItem?.representedObject = ""
        if !s.model.isEmpty { model.addItem(withTitle: s.model); model.lastItem?.representedObject = s.model; model.selectItem(at: 1) }
        jobsModel.addItem(withTitle: "Choose a model for jobs…"); jobsModel.lastItem?.representedObject = ""
        if !s.jobsModel.isEmpty { jobsModel.addItem(withTitle: s.jobsModel); jobsModel.lastItem?.representedObject = s.jobsModel; jobsModel.selectItem(at: 1) }
        models { [weak self] list in DispatchQueue.main.async { self?.fillModels(list) } }

        codex.target = self; codex.action = #selector(codexPicked); fillCodex()
        codexNote.font = .systemFont(ofSize: 11); codexNote.textColor = .secondaryLabelColor
        error.textColor = .systemRed; error.isHidden = true
        for p in [editor, model, jobsModel, codex] { p.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        name.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let newSessionButton = button("New Session…", self, #selector(startNewSession))
        let sessionNote = label("Archives this conversation and starts a fresh one. Notes carry over."); sessionNote.font = .systemFont(ofSize: 11); sessionNote.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [right("Name"), name],
            [right("Notes editor"), editor],
            [right("Model"), model],
            [right("Jobs model"), jobsModel],
            [right("Codex"), column([codex, codexNote])],
            [right("Session"), column([newSessionButton, sessionNote])],
        ])
        grid.rowSpacing = 14; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing; grid.rowAlignment = .firstBaseline
        let cancel = button("Cancel", self, #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", self, #selector(save)); save.keyEquivalent = "\r"
        let gap = NSView(); gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = row(gap, cancel, save)
        let filler = NSView(); filler.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = column([grid, error, filler, buttons])
        pin(stack, in: window.contentView!, inset: 24)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.center()
    }
    private func right(_ text: String) -> NSTextField { let l = label(text); l.alignment = .right; return l }
    func show() { window.makeKeyAndOrderFront(nil) }
    private func fillModels(_ list: [(id: String, name: String)]) {
        let selectedJob = jobsModel.selectedItem?.representedObject as? String ?? ""
        jobsModel.removeAllItems(); jobsModel.addItem(withTitle: "Choose a model for jobs…"); jobsModel.lastItem?.representedObject = ""
        for m in list { jobsModel.addItem(withTitle: m.name); jobsModel.lastItem?.representedObject = m.id }
        if !selectedJob.isEmpty && !list.contains(where: { $0.id == selectedJob }) { jobsModel.addItem(withTitle: selectedJob); jobsModel.lastItem?.representedObject = selectedJob }
        jobsModel.selectItem(at: max(0, jobsModel.indexOfItem(withRepresentedObject: selectedJob)))
        let current = model.selectedItem?.representedObject as? String ?? ""
        model.removeAllItems(); model.addItem(withTitle: "Codex default"); model.lastItem?.representedObject = ""
        var ids = list.map(\.id)
        for m in list { model.addItem(withTitle: m.name); model.lastItem?.representedObject = m.id }
        if !current.isEmpty && !ids.contains(current) { model.addItem(withTitle: current); model.lastItem?.representedObject = current; ids.append(current) }
        model.selectItem(at: max(0, model.indexOfItem(withRepresentedObject: current)))
    }
    private func fillCodex() {
        codex.removeAllItems()
        let found = Store.codexPath("")
        codex.addItem(withTitle: "Automatic"); codex.lastItem?.representedObject = ""
        if !codexChoice.isEmpty { codex.addItem(withTitle: codexChoice); codex.lastItem?.representedObject = codexChoice }
        codex.menu?.addItem(.separator()); codex.addItem(withTitle: "Choose Executable…"); codex.lastItem?.representedObject = "choose"
        codex.selectItem(at: codexChoice.isEmpty ? 0 : 1)
        let path = Store.codexPath(codexChoice)
        codexNote.stringValue = path.map { "Using \($0)" } ?? (codexChoice.isEmpty ? (found == nil ? "Not found. Install Codex, or choose it." : "") : "Not found at that path.")
    }
    @objc private func editorPicked() {
        guard editor.selectedItem?.representedObject as? String == "choose" else { return }
        let panel = NSOpenPanel(); panel.allowedFileTypes = ["app"]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            let appName = url.deletingPathExtension().lastPathComponent
            if editor.indexOfItem(withRepresentedObject: appName) < 0 { editor.insertItem(withTitle: appName, at: editor.numberOfItems - 2); editor.item(at: editor.numberOfItems - 3)?.representedObject = appName }
            editor.selectItem(at: editor.indexOfItem(withRepresentedObject: appName))
        } else { editor.selectItem(at: max(0, editor.indexOfItem(withRepresentedObject: store.settings.editor))) }
    }
    @objc private func codexPicked() {
        guard codex.selectedItem?.representedObject as? String == "choose" else { codexChoice = codex.selectedItem?.representedObject as? String ?? ""; fillCodex(); return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { codexChoice = url.path }
        fillCodex()
    }
    @objc private func startNewSession() { window.close(); newSession?() }
    @objc private func cancel() { window.close() }
    @objc private func save() {
        var s = store.settings
        s.title = name.stringValue.trimmingCharacters(in: .whitespaces)
        s.editor = editor.selectedItem?.representedObject as? String ?? ""
        s.model = model.selectedItem?.representedObject as? String ?? ""
        s.jobsModel = jobsModel.selectedItem?.representedObject as? String ?? ""
        s.codex = codexChoice
        do {
            try store.validate(s)
            let codexChanged = s.codex != store.settings.codex || s.model != store.settings.model
            let old = store.settings; store.settings = s
            do { try store.saveSettings() } catch { store.settings = old; throw error }
            window.close(); saved?(codexChanged)
        } catch { self.error.stringValue = error.localizedDescription; self.error.isHidden = false }
    }
}
