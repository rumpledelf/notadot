import AppKit

final class DotView: NSView {
    var color: NSColor = .systemGray { didSet { needsDisplay = true } }
    var hollow = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: 9) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); path.lineWidth = 1.5
        color.setStroke(); path.stroke()
        if !hollow { color.setFill(); path.fill() }
    }
    func show(_ state: RuntimeManager.State) {
        switch state {
        case .running: color = .systemGreen; hollow = false
        case .starting: color = .systemGreen; hollow = true
        case .stopped: color = .systemRed; hollow = false
        case .responding: color = .systemBlue; hollow = false
        case .unknown: color = .systemGray; hollow = false
        }
    }
}

func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector, tint: NSColor = .secondaryLabelColor) -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: action)
    b.isBordered = false; b.imagePosition = .imageOnly; b.contentTintColor = tint; b.toolTip = tip
    b.setAccessibilityLabel(tip)
    b.widthAnchor.constraint(equalToConstant: 22).isActive = true; b.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return b
}

/// A click target that isn't drawn as a button, for the project name and status.
final class ClickArea: NSStackView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A discovered listener remains externally owned; only offer its page, never a stop button.
final class OtherServerRow: NSView {
    var onOpen: (() -> Void)?
    init(server: OtherServer, projects: [Project]) {
        super.init(frame: .zero)
        let name = label(server.title(projects: projects), bold: true)
        name.lineBreakMode = .byTruncatingTail; name.maximumNumberOfLines = 1
        let detail = label(":\(server.port) · \(server.command)")
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [name, detail]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 1
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let open = iconButton("arrow.up.right", "Open in browser", self, #selector(openTapped))
        let row = NSStackView(views: [titles, spacer, open]); row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
        toolTip = "\(server.folder)\n\(server.pageURL(projects: projects).absoluteString)"
        pin(row, in: self, inset: 0)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func openTapped() { onOpen?() }
}

/// One project in the sidebar, laid out like fern-layout's section rows: status dot, name (click to expand),
/// small icon actions, and an inline editor underneath when expanded.
final class ProjectRow: SurfaceView, NSTextFieldDelegate {
    let projectID: String
    private let dot = DotView()
    private let status = label("")
    private let chevron = NSImageView()
    private let actions = NSStackView()
    private let editor = NSStackView()
    private let error = label("")
    private let runs = field(), port = field(), open = field()
    private var managed = false
    private var shownPort = 0
    var onToggle: (() -> Void)?, onStart: (() -> Void)?, onStop: (() -> Void)?, onOpen: (() -> Void)?, onLog: (() -> Void)?, onDelete: (() -> Void)?
    var onEdit: ((String, String, String) -> String?)? // runs, port, open → error message or nil

    init(project: Project) {
        projectID = project.id
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 7; layer?.borderWidth = 1
        surfaceBorderColor = .separatorColor; surfaceColor = .controlBackgroundColor
        let name = label(project.name, bold: true); name.lineBreakMode = .byTruncatingTail; name.maximumNumberOfLines = 1
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3
        let titles = NSStackView(views: [name, status]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 1
        chevron.contentTintColor = .tertiaryLabelColor
        let push = NSView(); push.setContentHuggingPriority(.init(1), for: .horizontal)
        let area = ClickArea(views: [titles, push, chevron]); area.orientation = .horizontal; area.alignment = .centerY; area.spacing = 4
        area.setContentHuggingPriority(.init(1), for: .horizontal) // Name fills the row so the icons sit at the right edge.
        area.onClick = { [weak self] in self?.onToggle?() }
        area.setAccessibilityLabel("\(project.name), show details")
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actions.orientation = .horizontal; actions.spacing = 0
        let header = NSStackView(views: [dot, area, actions]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 4)
        area.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        shownPort = project.port
        for (f, value) in [(runs, project.start), (port, project.port > 0 ? String(project.port) : ""), (open, project.url.isEmpty ? Project.defaultURL(project.port) : project.url)] {
            f.stringValue = value; f.delegate = self; f.font = .systemFont(ofSize: 11.5); f.controlSize = .small
        }
        runs.font = .monospacedSystemFont(ofSize: 11, weight: .regular); runs.placeholderString = "Empty: link only"
        open.placeholderString = "http://…"
        port.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let grid = NSGridView(views: [[small("Runs"), runs], [small("Port"), port], [small("Open"), open]])
        grid.rowSpacing = 5; grid.columnSpacing = 6; grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 150
        for f in [runs, open] { f.widthAnchor.constraint(equalToConstant: 150).isActive = true }
        error.textColor = .systemRed; error.font = .systemFont(ofSize: 11); error.isHidden = true
        let delete = iconButton("trash", "Delete project", self, #selector(deleteTapped), tint: .systemRed)
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let tools = NSStackView(views: [iconButton("doc.plaintext", "Log", self, #selector(logTapped)), spacer, delete]); tools.orientation = .horizontal
        editor.setViews([grid, error, tools], in: .leading); editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 6
        editor.edgeInsets = NSEdgeInsets(top: 4, left: 25, bottom: 8, right: 8)
        tools.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let stack = NSStackView(views: [header, editor]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     header.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        managed = project.managed
        setExpanded(false)
    }
    required init?(coder: NSCoder) { nil }
    private func small(_ text: String) -> NSTextField { let l = label(text); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; return l }

    func setExpanded(_ expanded: Bool) {
        editor.isHidden = !expanded
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        surfaceBorderColor = expanded ? .tertiaryLabelColor : .separatorColor
    }
    func update(_ s: RuntimeManager.Status) {
        dot.show(s.state); status.stringValue = s.text; status.toolTip = s.text
        var views: [NSView] = []
        // Start/stop only exist for projects with a Runs command; open is always offered and always tries.
        if managed && (s.state == .stopped || s.state == .unknown) { views.append(iconButton("play.fill", "Start", self, #selector(startTapped))) }
        if managed && (s.state == .running || s.state == .starting) { views.append(iconButton("stop.fill", "Stop", self, #selector(stopTapped))) }
        views.append(iconButton("arrow.up.right", "Open in browser", self, #selector(openTapped)))
        if actions.views.map(\.toolTip) != views.map(\.toolTip) { actions.setViews(views, in: .leading) }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        // A changed port carries the default address along with it; a custom address stays put.
        let newPort = Int(port.stringValue) ?? 0
        if newPort != shownPort, open.stringValue == Project.defaultURL(shownPort) { open.stringValue = Project.defaultURL(newPort) }
        let message = onEdit?(runs.stringValue.trimmingCharacters(in: .whitespaces), port.stringValue.trimmingCharacters(in: .whitespaces), open.stringValue.trimmingCharacters(in: .whitespaces))
        error.stringValue = message ?? ""; error.isHidden = message == nil
        if message == nil { managed = !runs.stringValue.trimmingCharacters(in: .whitespaces).isEmpty; shownPort = newPort }
    }
    @objc private func startTapped() { onStart?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func logTapped() { onLog?() }
    @objc private func deleteTapped() { onDelete?() }
}
