import AppKit

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    var store: Store!
    var runtimes: RuntimeManager!
    var tools: NativeTools!
    var jobs: Jobs!
    let notifications = Notifications()
    let jobsList = NSStackView(), jobsBox = NSStackView()
    var selectedJobID: String?
    var drafts: [String: String] = [:]
    var injectingJobNotes = false
    let codex = Codex()
    let probe = URLProbe()
    var window: NSWindow!
    let transcript = NSTextView(), composer = NSTextView()
    let status = label(""), titleLabel = label("", bold: true)
    let connDot = DotView(), connLabel = label("Disconnected"), versionLabel = label("")
    let projectList = NSStackView(), projectCount = label("")
    var projectRows: [String: ProjectRow] = [:], expandedID: String?
    let othersBox = SurfaceStackView(), othersLabel = label("")
    let otherServerList = NSStackView()
    var askOthersButton: NSButton!
    var otherServers: [OtherServer] = [], scanning = false, lastScan = Date.distantPast
    let notesOverlay = SurfaceStackView(), notesView = NSTextView()
    var sendButton: NSButton!, stopButton: NSButton!, compactButton: NSButton!, notesButton: NSButton!
    var settingsWindow: SettingsWindow?, addSheet: AddProjectSheet?
    var timer: Timer?, renderTimer: Timer?, saveTimer: Timer?
    var ready = false, busy = false
    var turnID: String?
    var activeThreadID: String?
    var codexVersion = ""
    var attachment: String?
    var toolItems: [String: [String: Any]] = [:]
    var expandedActivity: Set<String> = []
    var expandedTools: Set<String> = []
    var quitting = false
    var notesDue = true // Like AGENTS.md: the next turn carries the notes after a (re)connect or compaction.

    func applicationDidFinishLaunching(_ notification: Notification) {
        let smoke = CommandLine.arguments.contains("--ui-smoke")
        do { store = try Store(directory: smoke ? URL(fileURLWithPath: "/tmp/notadot-ui-smoke") : nil) } catch { NSAlert(error: error).runModal(); NSApp.terminate(nil); return }
        runtimes = RuntimeManager(directory: store.directory); tools = NativeTools(store: store, runtimes: runtimes)
        jobs = Jobs(store: store, codex: codex)
        jobs.changed = { [weak self] in self?.refreshJobs(); self?.scheduleRender(); self?.updateControls() }
        jobs.persistenceError = { [weak self] error in self?.showError(error) }
        jobs.report = { [weak self] job, state in self?.reportJob(job, state) }
        tools.jobAction = { [weak self] args, done in self?.jobs.perform(args, completion: done) }
        notifications.openJob = { [weak self] id in self?.selectJob(id); self?.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        buildMenu(); buildWindow()
        tools.changed = { [weak self] in self?.refreshProjects() }
        probe.changed = { [weak self] in self?.refreshProjects() }
        codex.event = { [weak self] method, params in self?.event(method, params) }
        codex.request = { [weak self] id, method, params in self?.serverRequest(id, method, params) }
        codex.disconnected = { [weak self] message in
            guard let self = self, !self.quitting else { return }
            self.ready = false; self.busy = false; self.status.stringValue = message; self.updateControls()
            self.jobs.disconnected()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshProjects(); if self?.jobs.hasWorking == true { self?.jobs.save() } }
        if smoke { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.uiSmoke() } }
        else { connect() }
    }
    /// Each step waits a moment so the window server has drawn the change before it's captured.
    private func uiSmoke() {
        store.settings.title = "Bottled Fey"
        let demo = Project(name: "Garden project", path: store.directory.appendingPathComponent("garden").path, port: 8117, start: "", url: "http://localhost:8117/garden/")
        store.settings.projects = [demo]
        otherServers = [OtherServer(pid: 123, command: "node", port: 8117, folder: demo.path + "/web")]
        applyConfiguredName(); refreshProjects()
        guard window.title == "Bottled Fey", askOthersButton.title == "Ask Bottled Fey", othersLabel.stringValue.contains("Bottled Fey"),
              otherServerList.arrangedSubviews.count == 1,
              otherServerList.arrangedSubviews.first?.toolTip?.contains("http://localhost:8117/garden/") == true,
              NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.title == "Quit Bottled Fey" }) == true else {
            fputs("FAIL: configured name and external server row\n", stderr); exit(1)
        }
        print("PASS: configured name is used in sidebar and menu, external server has its project and exact page address")
        let commentary = "Let me look at your calendar and see if it is crowded."
        store.session.messages = [
            Message(role: "assistant", text: commentary, itemID: "activity+/=", phase: "commentary", turnID: "preview"),
            Message(role: "tool", text: "cd /Users/screenshot-person/private-project\nPRIVATE TOOL RESULT", itemID: "preview-tool"),
            Message(role: "assistant", text: "Your afternoon is free.", itemID: "preview-final", phase: "final_answer", turnID: "preview")
        ]
        expandedActivity.removeAll(); expandedTools.removeAll(); render()
        var activityLink: Any?, toolLink: Any?
        transcript.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: transcript.textStorage?.length ?? 0)) { value, _, _ in
            if let url = value as? URL, url.scheme == "notadot-activity" { activityLink = url }
            if let url = value as? URL, url.scheme == "notadot-tool" { toolLink = url }
        }
        guard let link = activityLink, !transcript.string.contains(commentary), !transcript.string.contains("PRIVATE TOOL RESULT"),
              textView(transcript, clickedOnLink: link, at: 0), transcript.string.contains(commentary),
              textView(transcript, clickedOnLink: link, at: 0), !transcript.string.contains(commentary) else {
            fputs("FAIL: activity disclosure must start collapsed and toggle only on click\n", stderr); exit(1)
        }
        print("PASS: commentary starts collapsed, expands and collapses on click, and tool results stay hidden")
        guard let tool = toolLink, transcript.string.contains("Ran tools"), !transcript.string.contains("screenshot-person"), !transcript.string.contains("PRIVATE TOOL RESULT"), transcript.linkTextAttributes?.isEmpty == true,
              textView(transcript, clickedOnLink: tool, at: 0), transcript.string.contains("PRIVATE TOOL RESULT"), !transcript.string.contains(commentary),
              textView(transcript, clickedOnLink: tool, at: 0), !transcript.string.contains("PRIVATE TOOL RESULT") else {
            fputs("FAIL: tool details must expand and collapse independently on click\n", stderr); exit(1)
        }
        print("PASS: tools show only a neutral Ran tools label until clicked, without link styling or private paths")
        composer.string = "Draft message — check text, selection and caret contrast."
        if store.jobs.isEmpty {
            var sample = Job(title: "Job preview", folder: store.directory.path, model: "Preview model", task: "UI fixture")
            sample.state = .done; sample.messages = [Message(role: "you", text: "Read the brief and report back."), Message(role: "assistant", text: "This job has its own conversation. Use Housekeeper chat to return.")]
            store.jobs = [sample]
        }
        refreshJobs()
        if let first = store.settings.projects.first { toggleRow(first.id) }
        func captureAppearance(_ index: Int) {
            let modes: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua), ("light-again", .aqua)]
            guard index < modes.count else {
                print("UI smoke test passed; images in \(self.store.directory.path)"); NSApp.terminate(nil); return
            }
            let (name, appearance) = modes[index]
            self.window.appearance = NSAppearance(named: appearance)
            let steps: [() throws -> Void] = [
                { try self.captureSmoke(self.window, name + "-main"); self.selectJob(self.store.jobs.first?.id) },
                { try self.captureSmoke(self.window, name + "-job"); self.selectJob(nil); self.toggleNotes() },
                {
                    try self.captureSmoke(self.window, name + "-notes"); self.toggleNotes(); self.settings()
                    if let w = self.settingsWindow?.window { w.appearance = NSAppearance(named: appearance) }
                },
                {
                    guard let w = self.settingsWindow?.window else { throw AppError.message("Settings did not open") }
                    try self.captureSmoke(w, name + "-settings"); w.close()
                }
            ]
            func next(_ step: Int) {
                if step == steps.count { captureAppearance(index + 1); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    do { try steps[step](); next(step + 1) } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
                }
            }
            next(0)
        }
        captureAppearance(0)
    }

    private func captureSmoke(_ window: NSWindow, _ name: String) throws {
        guard let view = window.contentView else { throw AppError.message("Missing view") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), .boundsIgnoreFraming), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw AppError.message("Could not capture \(name): bounds \(view.bounds), window \(window.windowNumber)") }
        try data.write(to: store.directory.appendingPathComponent(name + ".png"))
        print("PASS: \(name) layout and capture · \(view.bounds)")
    }

    // MARK: Window

    private func buildMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(title: store.settings.title, action: nil, keyEquivalent: ""); menu.addItem(appItem)
        let appMenu = NSMenu(title: store.settings.title); appItem.submenu = appMenu
        for (title, action, key) in [("Settings…", #selector(settings), ","), ("Notes", #selector(toggleNotes), "n"), ("Add Project…", #selector(addProject), "p"), ("Reconnect Codex", #selector(reconnect), "r"), ("Quit \(store.settings.title)", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; appMenu.addItem(item)
        }
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, selector, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        let stop = NSMenuItem(title: "Stop", action: #selector(interrupt), keyEquivalent: "."); stop.target = self; edit.addItem(stop)
        NSApp.mainMenu = menu
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = store.settings.title; window.minSize = NSSize(width: 820, height: 560); window.delegate = self; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NotadotMain")
        let sidebar = buildSidebar(), chat = buildChat()
        let root = NSStackView(views: [sidebar, chat]); root.orientation = .horizontal; root.spacing = 0; root.alignment = .top
        root.distribution = .fill; chat.setContentHuggingPriority(.init(1), for: .horizontal) // The chat takes whatever width the sidebar leaves.
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
                                     root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
                                     sidebar.heightAnchor.constraint(equalTo: root.heightAnchor), chat.heightAnchor.constraint(equalTo: root.heightAnchor)])
        render(); refreshProjects(); updateControls(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in guard let self = self else { return }; self.window.makeFirstResponder(self.composer) }
    }
    private func buildSidebar() -> NSView {
        let background = NSVisualEffectView(); background.material = .sidebar; background.blendingMode = .behindWindow
        background.widthAnchor.constraint(equalToConstant: 260).isActive = true

        // Notes: view formatted over the chat, or edit in the configured external editor.
        notesButton = NSButton(title: "Notes", image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!, target: self, action: #selector(toggleNotes))
        notesButton.isBordered = false; notesButton.imagePosition = .imageLeading; notesButton.font = .systemFont(ofSize: 13, weight: .medium); notesButton.contentTintColor = .labelColor
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let notesRow = NSStackView(views: [notesButton, spacer, iconButton("pencil", "Edit notes in your editor", self, #selector(externalNotes))])
        notesRow.orientation = .horizontal; notesRow.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 2)

        let heading = label("PROJECTS", bold: true); heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textColor = .secondaryLabelColor
        projectCount.font = .systemFont(ofSize: 11); projectCount.textColor = .secondaryLabelColor
        let spacer2 = NSView(); spacer2.setContentHuggingPriority(.init(1), for: .horizontal)
        let headRow = NSStackView(views: [heading, spacer2, projectCount]); headRow.orientation = .horizontal; headRow.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        let add = NSButton(title: "Add a project", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!, target: self, action: #selector(addProject))
        add.bezelStyle = .roundRect; add.imagePosition = .imageLeading

        projectList.orientation = .vertical; projectList.alignment = .leading; projectList.spacing = 4
        let projectScroll = NSScrollView(); projectScroll.hasVerticalScroller = true; projectScroll.drawsBackground = false
        let projectDoc = FlippedView(); projectDoc.translatesAutoresizingMaskIntoConstraints = false; projectScroll.documentView = projectDoc
        jobsList.orientation = .vertical; jobsList.alignment = .leading; jobsList.spacing = 4
        let jobsHeading = label("JOBS", bold: true); jobsHeading.font = .systemFont(ofSize: 11, weight: .semibold); jobsHeading.textColor = .secondaryLabelColor
        jobsBox.setViews([jobsHeading, button("Housekeeper chat", self, #selector(showHousekeeper)), jobsList], in: .leading)
        jobsBox.orientation = .vertical; jobsBox.alignment = .leading; jobsBox.spacing = 8; jobsBox.isHidden = true
        let lists = column([projectList, jobsBox]); lists.translatesAutoresizingMaskIntoConstraints = false; projectDoc.addSubview(lists)
        NSLayoutConstraint.activate([projectDoc.widthAnchor.constraint(equalTo: projectScroll.contentView.widthAnchor), lists.leadingAnchor.constraint(equalTo: projectDoc.leadingAnchor), lists.trailingAnchor.constraint(equalTo: projectDoc.trailingAnchor), lists.topAnchor.constraint(equalTo: projectDoc.topAnchor), lists.bottomAnchor.constraint(equalTo: projectDoc.bottomAnchor), projectList.widthAnchor.constraint(equalTo: lists.widthAnchor), jobsBox.widthAnchor.constraint(equalTo: lists.widthAnchor), jobsList.widthAnchor.constraint(equalTo: lists.widthAnchor)])

        // Servers Notadot didn't start: one notice, handed to the chat to sort out.
        othersLabel.font = .systemFont(ofSize: 12)
        askOthersButton = NSButton(title: "Ask \(store.settings.title)", target: self, action: #selector(askAboutOthers)); askOthersButton.bezelStyle = .roundRect; askOthersButton.controlSize = .small
        otherServerList.orientation = .vertical; otherServerList.alignment = .leading; otherServerList.spacing = 8
        othersBox.setViews([othersLabel, otherServerList, askOthersButton], in: .leading); othersBox.orientation = .vertical; othersBox.alignment = .leading; othersBox.spacing = 8
        othersBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        othersBox.wantsLayer = true; othersBox.layer?.cornerRadius = 7; othersBox.layer?.borderWidth = 1
        othersBox.surfaceBorderColor = NSColor.systemOrange.withAlphaComponent(0.5); othersBox.surfaceColor = NSColor.systemOrange.withAlphaComponent(0.08)
        othersBox.isHidden = true
        otherServerList.widthAnchor.constraint(equalTo: othersBox.widthAnchor, constant: -20).isActive = true

        // Bottom left: connection, version, reconnect, settings.
        versionLabel.font = .systemFont(ofSize: 11); versionLabel.textColor = .secondaryLabelColor; connLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let connText = NSStackView(views: [connLabel, versionLabel]); connText.orientation = .vertical; connText.alignment = .leading; connText.spacing = 0
        let spacer3 = NSView(); spacer3.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [connDot, connText, spacer3, iconButton("arrow.clockwise", "Reconnect Codex", self, #selector(reconnect)), iconButton("gearshape", "Settings", self, #selector(settings))])
        bottom.orientation = .horizontal; bottom.spacing = 8; bottom.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 0)
        let line = NSBox(); line.boxType = .separator

        let column = NSStackView(views: [notesRow, headRow, add, projectScroll, othersBox, line, bottom])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        column.setCustomSpacing(16, after: notesRow)
        for v in [notesRow, headRow, add, projectScroll, othersBox, line, bottom] { v.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20).isActive = true }
        projectScroll.setContentHuggingPriority(.init(1), for: .vertical)
        pin(column, in: background, inset: 0)
        return background
    }
    private func buildChat() -> NSView {
        let container = SurfaceView()
        container.wantsLayer = true; container.surfaceColor = .textBackgroundColor // One surface for header, transcript and composer.
        titleLabel.stringValue = store.settings.title; titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail; status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        compactButton = button("Compact", self, #selector(compact)); compactButton.bezelStyle = .roundRect; compactButton.toolTip = "Ask Codex to compact its context. Notes reload afterwards."
        let headSpacer = NSView(); headSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, status, headSpacer, compactButton]); header.orientation = .horizontal; header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 10, right: 16)

        transcript.drawsBackground = false; transcript.textColor = .textColor
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = true; transcript.delegate = self; transcript.textContainerInset = NSSize(width: 24, height: 18)
        // Preserve each span's explicit color instead of AppKit's default blue link styling.
        transcript.linkTextAttributes = [:]
        transcript.autoresizingMask = [.width]; transcript.isVerticallyResizable = true; transcript.textContainer?.widthTracksTextView = true
        let history = NSScrollView(); history.hasVerticalScroller = true; history.documentView = transcript; history.borderType = .noBorder; history.drawsBackground = false

        // Notes view sits over the chat; read-only, editing happens in the external editor.
        notesView.drawsBackground = false; notesView.textColor = .textColor
        notesView.isEditable = false; notesView.isSelectable = true; notesView.delegate = self; notesView.textContainerInset = NSSize(width: 32, height: 20)
        notesView.autoresizingMask = [.width]; notesView.isVerticallyResizable = true; notesView.textContainer?.widthTracksTextView = true
        let notesScroll = NSScrollView(); notesScroll.hasVerticalScroller = true; notesScroll.documentView = notesView; notesScroll.drawsBackground = false
        let notesTitle = label("Notes", bold: true); let notesHint = label("Read-only · the assistant reads and adds to these"); notesHint.textColor = .secondaryLabelColor; notesHint.font = .systemFont(ofSize: 12)
        let notesSpacer = NSView(); notesSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let notesHead = NSStackView(views: [notesTitle, notesHint, notesSpacer, iconButton("pencil", "Edit notes in your editor", self, #selector(externalNotes)), iconButton("xmark", "Close notes", self, #selector(toggleNotes))])
        notesHead.orientation = .horizontal; notesHead.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 12)
        notesOverlay.setViews([notesHead, notesScroll], in: .leading); notesOverlay.orientation = .vertical; notesOverlay.spacing = 0
        notesOverlay.wantsLayer = true; notesOverlay.surfaceColor = .textBackgroundColor; notesOverlay.isHidden = true
        for v in [notesHead, notesScroll] { v.widthAnchor.constraint(equalTo: notesOverlay.widthAnchor).isActive = true }

        // Composer: text across the full width, then a row of attach … stop, send underneath.
        composer.isRichText = false; composer.font = .systemFont(ofSize: 14); composer.delegate = self; composer.drawsBackground = false
        composer.textColor = .textColor; composer.insertionPointColor = .textColor
        composer.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        composer.textContainerInset = NSSize(width: 0, height: 2); composer.textContainer?.lineFragmentPadding = 0
        composer.autoresizingMask = [.width]; composer.isVerticallyResizable = true; composer.textContainer?.widthTracksTextView = true
        let input = NSScrollView(); input.hasVerticalScroller = true; input.autohidesScrollers = true; input.documentView = composer; input.drawsBackground = false
        input.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let attach = iconButton("plus.circle", "Attach", self, #selector(showAttachMenu(_:)))
        stopButton = iconButton("stop.circle.fill", "Stop (⌘.)", self, #selector(interrupt), tint: .secondaryLabelColor)
        sendButton = iconButton("arrow.up.circle.fill", "Send (↵)", self, #selector(sendMessage), tint: .controlAccentColor)
        for b in [attach, stopButton!, sendButton!] { b.symbolConfiguration = .init(pointSize: 17, weight: .regular) }
        let buttonGap = NSView(); buttonGap.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [attach, buttonGap, stopButton, sendButton]); buttons.orientation = .horizontal; buttons.spacing = 4
        let box = SurfaceStackView(views: [input, buttons]); box.orientation = .vertical; box.spacing = 4
        box.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 6, right: 8)
        for v in [input, buttons] { v.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true }
        box.wantsLayer = true; box.layer?.cornerRadius = 12; box.layer?.borderWidth = 1; box.surfaceBorderColor = .separatorColor
        box.surfaceColor = .textBackgroundColor
        let hint = label("↵ to send · ⇧↵ for a new line · Steer while working · ⌘. to stop"); hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [box, hint]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 5
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 14, right: 20)
        box.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -40).isActive = true

        let line = NSBox(); line.boxType = .separator
        for v in [header, line, history, footer, notesOverlay] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor), header.leadingAnchor.constraint(equalTo: container.leadingAnchor), header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.topAnchor.constraint(equalTo: header.bottomAnchor), line.leadingAnchor.constraint(equalTo: container.leadingAnchor), line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            history.topAnchor.constraint(equalTo: line.bottomAnchor), history.leadingAnchor.constraint(equalTo: container.leadingAnchor), history.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: history.bottomAnchor), footer.leadingAnchor.constraint(equalTo: container.leadingAnchor), footer.trailingAnchor.constraint(equalTo: container.trailingAnchor), footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            notesOverlay.topAnchor.constraint(equalTo: container.topAnchor), notesOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor), notesOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor), notesOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        return container
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return sends; Shift-Return adds a line. Mid-composition (an input method's marked text) Return confirms the text instead.
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertText("\n", replacementRange: textView.selectedRange()); return true }
        sendMessage(); return true
    }
    private func updateControls() {
        if let id = selectedJobID, let job = jobs.job(id) {
            titleLabel.stringValue = job.title
            status.stringValue = "\(job.state.rawValue.capitalized) · \(job.model)"
            sendButton.isEnabled = ready && (job.state != .working || job.turnID != nil)
            stopButton.isHidden = job.turnID == nil && attachment == nil
            compactButton.isEnabled = false
            sendButton.toolTip = job.turnID == nil ? "Send to job" : "Steer job"
            return
        }
        titleLabel.stringValue = store.settings.title
        sendButton.isEnabled = ready && (!busy || turnID != nil)
        sendButton.toolTip = busy ? "Steer the current turn (↵)" : "Send (↵)"
        stopButton.isHidden = !(busy || attachment != nil)
        compactButton.isEnabled = ready && !busy && store.session.threadID != nil
        connDot.show(ready ? .running : codex.running ? .starting : .unknown)
        connLabel.stringValue = ready ? "Codex connected" : codex.running ? "Connecting…" : "Codex disconnected"
        versionLabel.stringValue = codexVersion.isEmpty ? "codex" : codexVersion
    }

    // MARK: Transcript

    private func persist() {
        do { try store.saveSession() } catch { status.stringValue = "Could not save session: \(error.localizedDescription)" }
    }
    private func append(_ role: String, _ text: String, id: String? = nil) {
        store.session.messages.append(Message(role: role, text: text, itemID: id)); persist(); scheduleRender()
    }
    private func scheduleRender() {
        guard renderTimer == nil else { return }
        renderTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in self?.renderTimer = nil; self?.render() }
    }
    private func render() {
        let visible = Transcript.visible(selectedJobID.flatMap { jobs.job($0)?.messages } ?? store.session.messages).suffix(250)
        let content = NSMutableAttributedString()
        if visible.isEmpty {
            content.append(NSAttributedString(string: "A home for the housekeeping session.\n\nAdd your projects on the left, then say hello. Your notes load into the chat automatically.\n", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for m in visible {
            let spacing = NSMutableParagraphStyle(); spacing.paragraphSpacingBefore = 14
            switch m.role {
            case "you":
                // Your messages sit to the right, like a chat, without a bubble the text view can't draw well.
                let style = NSMutableParagraphStyle(); style.alignment = .right; style.headIndent = 120; style.firstLineHeadIndent = 120; style.paragraphSpacingBefore = 16; style.paragraphSpacing = 2
                content.append(NSAttributedString(string: m.text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10), .paragraphStyle: style]))
            case "assistant":
                if m.phase == "commentary" {
                    let key = m.itemID ?? (m.turnID ?? "") + m.text
                    let expanded = expandedActivity.contains(key)
                    let link = URL(string: "notadot-activity://toggle/" + Data(key.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
                    content.append(NSAttributedString(string: (expanded ? "▾  " : "›  ") + "Activity\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: spacing, .link: link]))
                    if expanded { content.append(NSAttributedString(string: m.text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])) }
                    continue
                }
                let reply = NSMutableAttributedString(attributedString: Markdown.render(m.text))
                if reply.length > 0 { reply.addAttribute(.paragraphStyle, value: { () -> NSParagraphStyle in
                    let s = (reply.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    s.paragraphSpacingBefore = 14; return s }(), range: NSRange(location: 0, length: 1)) }
                content.append(reply); content.append(NSAttributedString(string: "\n"))
            case "tool":
                let key = (selectedJobID ?? "housekeeper") + ":" + (m.itemID ?? m.text)
                let expanded = expandedTools.contains(key)
                let link = URL(string: "notadot-tool://toggle/" + Data(key.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
                content.append(NSAttributedString(string: (expanded ? "▾  " : "›  ") + "Ran tools\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: spacing, .link: link]))
                if expanded {
                    let details = m.toolDetails.flatMap { $0.isEmpty ? nil : $0 } ?? m.text
                    content.append(NSAttributedString(string: details + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
                }
            case "error":
                content.append(NSAttributedString(string: m.text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemRed, .paragraphStyle: spacing]))
            default:
                content.append(NSAttributedString(string: m.text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: spacing]))
            }
        }
        let scroll = transcript.enclosingScrollView
        let nearBottom = scroll.map { $0.contentView.bounds.maxY >= transcript.bounds.maxY - 80 } ?? true
        transcript.textStorage?.setAttributedString(content)
        if nearBottom { transcript.scrollToEndOfDocument(nil) }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if (textView === transcript || textView === notesView), let url = link as? URL, url.isFileURL {
            openLocalFile(url); return true
        }
        guard textView === transcript, let url = link as? URL, ["notadot-activity", "notadot-tool"].contains(url.scheme ?? ""),
              let encoded = url.path.dropFirst().removingPercentEncoding,
              let data = Data(base64Encoded: encoded), let key = String(data: data, encoding: .utf8) else { return false }
        if url.scheme == "notadot-tool" {
            if expandedTools.contains(key) { expandedTools.remove(key) } else { expandedTools.insert(key) }
        } else {
            if expandedActivity.contains(key) { expandedActivity.remove(key) } else { expandedActivity.insert(key) }
        }
        render(); return true
    }

    // MARK: Codex

    private func instructions() -> String {
        Housekeeper.instructions(name: store.settings.title, notes: store.settings.notes)
    }
    private var workspaceRoots: [String] { Array(Set(store.settings.projects.map(\.path) + [store.directory.path])).sorted() }
    private func connect() {
        ready = false; updateControls(); status.stringValue = "Connecting to Codex…"
        do {
            guard let path = Store.codexPath(store.settings.codex) else { throw AppError.message(store.settings.codex.isEmpty ? "Codex was not found. Install it, or choose it in Settings." : "Codex was not found at \(store.settings.codex). Set Codex to Automatic in Settings.") }
            // Codex updates often; showing the version makes a behaviour change easy to connect to an update.
            codexVersion = RuntimeManager.command(path, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try codex.start(path: path, cwd: FileManager.default.homeDirectoryForCurrentUser.path, title: store.settings.title) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error): self.showError(error)
                case .success: self.openThread()
                }
            }
            updateControls()
        } catch { showError(error); updateControls() }
    }
    private func openThread() {
        // Codex may write inside your projects and Notadot's own folder; nowhere else without asking.
        var params: [String: Any] = ["cwd": FileManager.default.homeDirectoryForCurrentUser.path, "runtimeWorkspaceRoots": workspaceRoots, "developerInstructions": instructions()]
        if !store.settings.model.isEmpty { params["model"] = store.settings.model }
        let method: String
        if let id = store.session.threadID { method = "thread/resume"; params["threadId"] = id }
        else { method = "thread/start"; params["dynamicTools"] = NativeTools.definitions }
        codex.call(method, params) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error): self.showError(error)
            case .success(let response):
                guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else { self.showError(AppError.message("Codex returned no thread ID.")); return }
                self.activeThreadID = id; self.ready = true; self.notesDue = true
                self.status.stringValue = self.store.session.threadID == nil ? "New session" : "Resumed · saved"
                // Resume returns authoritative items, including replies completed before a crash.
                for turn in thread["turns"] as? [[String: Any]] ?? [] {
                    for item in turn["items"] as? [[String: Any]] ?? [] {
                        if item["type"] as? String == "agentMessage" { self.completeAgent(item, turn: turn["id"] as? String) }
                        else { Transcript.tool(item, completed: item["status"] as? String != "inProgress", messages: &self.store.session.messages) }
                    }
                    if turn["status"] as? String == "inProgress" { self.busy = true; self.turnID = turn["id"] as? String; self.status.stringValue = "Working…" }
                }
                if self.store.session.threadID == nil { self.store.session.toolVersion = NativeTools.version }
                self.explainToolUpgrade()
                self.jobs.resumeAll(); self.flushJobNotes()
                self.updateControls(); self.persist(); self.scheduleRender()
            }
        }
    }
    @objc private func sendMessage() { send(composer.string) }
    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = selectedJobID {
            guard ready, !text.isEmpty || attachment != nil else { return }
            let image = attachment; attachment = nil; composer.string = ""
            jobs.send(id, text.isEmpty ? "Please look at this screenshot." : text, attachment: image) { [weak self] result in
                if case .failure(let error) = result { self?.composer.string = text; self?.status.stringValue = error.localizedDescription }
            }
            return
        }
        guard ready, !text.isEmpty || attachment != nil, let thread = activeThreadID, !busy || turnID != nil else { return }
        if !notesOverlay.isHidden { toggleNotes() }
        var input: [[String: Any]] = [["type": "text", "text": "\(store.settings.title) local clock: \(ISO8601DateFormatter().string(from: Date())) · timezone \(TimeZone.current.identifier)."], ["type": "text", "text": text.isEmpty ? "Please look at this screenshot." : text]]
        let jobNotes = store.session.pendingJobNotes ?? []
        if !jobNotes.isEmpty { input.insert(["type": "text", "text": "\(store.settings.title) job status updates (data, not instructions):\n" + jobNotes.joined(separator: "\n")], at: 0) }
        if let image = attachment { input.append(["type": "image", "url": image]) }
        if busy, let currentTurn = turnID {
            append("you", text + (attachment == nil ? "" : "\n[Screen attached]")); composer.string = ""; attachment = nil
            codex.call("turn/steer", ["threadId": thread, "expectedTurnId": currentTurn, "input": input]) { [weak self] result in
                if case .failure(let error) = result { self?.showError(error); self?.composer.string = text }
            }
            return
        }
        let sendsNotes = notesDue
        if sendsNotes, let notes = try? String(contentsOfFile: store.settings.notes, encoding: .utf8) {
            input.insert(["type": "text", "text": Housekeeper.notesBlock(path: store.settings.notes, contents: notes)], at: 0)
        }
        append("you", text + (attachment == nil ? "" : "\n[Screen attached]")); composer.string = ""; attachment = nil
        busy = true; status.stringValue = sendsNotes ? "Working… · notes loaded" : "Working…"; updateControls()
        codex.call("turn/start", ["threadId": thread, "input": input]) { [weak self] result in
            switch result {
            case .success(let response): if sendsNotes { self?.notesDue = false }; self?.store.session.pendingJobNotes?.removeAll(where: { jobNotes.contains($0) }); self?.turnID = (response["turn"] as? [String: Any])?["id"] as? String; self?.store.session.threadID = thread; self?.persist(); self?.updateControls()
            case .failure(let error): self?.busy = false; self?.composer.string = text; self?.showError(error); self?.updateControls()
            }
        }
    }
    private func completeAgent(_ item: [String: Any], turn: String? = nil) {
        Transcript.item(item, turn: turn ?? turnID, messages: &store.session.messages)
    }
    private func event(_ method: String, _ p: [String: Any]) {
        if let item = p["item"] as? [String: Any], let id = item["id"] as? String, item["type"] as? String == "fileChange" { toolItems[id] = item }
        if jobs.event(method, p) { return }
        if let thread = p["threadId"] as? String, thread != activeThreadID { return }
        switch method {
        case "turn/started": busy = true; store.session.threadID = activeThreadID; persist(); turnID = (p["turn"] as? [String: Any])?["id"] as? String; status.stringValue = "Working…"; updateControls()
        case "item/agentMessage/delta":
            Transcript.delta(p, turn: p["turnId"] as? String ?? turnID, messages: &store.session.messages)
            scheduleRender()
            if saveTimer == nil { saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.saveTimer = nil; self?.persist() } }
        case "item/started", "item/completed":
            guard let item = p["item"] as? [String: Any], let type = item["type"] as? String else { return }
            if let id = item["id"] as? String, type == "fileChange" { toolItems[id] = item }
            if type == "agentMessage" { completeAgent(item, turn: p["turnId"] as? String); persist(); scheduleRender() }
            else if Transcript.toolTypes.contains(type) {
                Transcript.tool(item, completed: method == "item/completed", messages: &store.session.messages)
                persist(); scheduleRender()
            }
        case "turn/completed":
            busy = false; turnID = nil
            let turn = p["turn"] as? [String: Any] ?? [:]; let state = turn["status"] as? String ?? "completed"
            status.stringValue = state == "completed" ? "Saved" : "Turn \(state)"
            if let error = turn["error"] as? [String: Any] { append("error", error["message"] as? String ?? "Turn failed") }
            persist(); updateControls(); flushJobNotes()
        case "thread/tokenUsage/updated":
            let usage = p["tokenUsage"] as? [String: Any] ?? [:]
            let last = usage["last"] as? [String: Any] ?? [:]
            if let n = last["totalTokens"] as? Int { versionLabel.stringValue = "\(codexVersion) · \(n.formattedCompat) tokens" }
        case "thread/compacted": notesDue = true; status.stringValue = "Compacted · notes reload with your next message"
        case "error":
            if let error = p["error"] as? [String: Any] { append("error", error["message"] as? String ?? "Codex error") }
        default: break
        }
    }
    private func serverRequest(_ id: Any, _ method: String, _ p: [String: Any]) {
        let job = (p["threadId"] as? String).flatMap { jobs.job($0) }
        if let job = job {
            if method == "item/tool/call" { codex.reply(id, ["success": false, "contentItems": [["type": "inputText", "text": "Jobs cannot use \(store.settings.title) native tools."]]]); return }
            jobs.waiting(job.id)
        }
        defer { if let job = job { jobs.approvalResolved(job.id) } }
        if method == "item/tool/call" {
            guard p["threadId"] as? String == activeThreadID else { codex.reply(id, ["success": false, "contentItems": [["type": "inputText", "text": "Only the housekeeper may use native tools."]]]); return }
            guard p["tool"] as? String == "notadot" else { codex.reply(id, ["success": false, "contentItems": [["type": "inputText", "text": "Unknown app tool"]]]); return }
            tools.performAsync(p["arguments"] as? [String: Any] ?? [:]) { [weak self] result in
                switch result {
                case .success(let content): self?.codex.reply(id, ["success": true, "contentItems": content])
                case .failure(let error): self?.codex.reply(id, ["success": false, "contentItems": [["type": "inputText", "text": error.localizedDescription]]])
                }
            }
        } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            let alert = NSAlert(); alert.messageText = job.map { "Job ‘\($0.title)’ requests approval" } ?? "Codex requests approval"
            var detail = p["reason"] as? String ?? "Review this action before allowing it."
            if let command = p["command"] as? String { detail += "\n\n" + command }
            if let cwd = p["cwd"] as? String { detail += "\n\nFolder: " + cwd }
            if let changes = p["changes"] { detail += "\n\n\(changes)" }
            if let itemID = p["itemId"] as? String, let changes = toolItems[itemID]?["changes"],
               let data = try? JSONSerialization.data(withJSONObject: changes, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { detail += "\n\n" + text }
            alert.informativeText = "Review the requested action below."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300)); scroll.hasVerticalScroller = true
            let textView = NSTextView(frame: scroll.bounds); textView.string = detail; textView.isEditable = false; textView.isRichText = false; textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular); textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true; textView.textContainer?.widthTracksTextView = true; scroll.documentView = textView
            alert.accessoryView = scroll; alert.addButton(withTitle: "Allow once"); alert.addButton(withTitle: "Deny")
            codex.reply(id, ["decision": alert.runModal() == .alertFirstButtonReturn ? "accept" : "decline"])
        } else if method == "item/tool/requestUserInput" {
            var answers: [String: Any] = [:]
            for question in p["questions"] as? [[String: Any]] ?? [] {
                let alert = NSAlert(); alert.messageText = job.map { "Job ‘\($0.title)’ needs input" } ?? question["header"] as? String ?? "Codex needs input"; alert.informativeText = question["question"] as? String ?? ""
                let input = field(); input.frame = NSRect(x: 0, y: 0, width: 420, height: 26)
                if let options = question["options"] as? [[String: Any]] { alert.informativeText += "\n\n" + options.compactMap { $0["label"] as? String }.joined(separator: "\n") }
                alert.accessoryView = input; alert.addButton(withTitle: "Send"); alert.addButton(withTitle: "Cancel")
                let response = alert.runModal() == .alertFirstButtonReturn ? input.stringValue : "User cancelled."
                if let key = question["id"] as? String { answers[key] = ["answers": [response]] }
            }
            codex.reply(id, ["answers": answers])
        } else if method == "item/permissions/requestApproval" {
            let permissions = p["permissions"] as? [String: Any] ?? [:]
            let data = try? JSONSerialization.data(withJSONObject: permissions, options: [.prettyPrinted, .sortedKeys])
            let alert = NSAlert(); alert.messageText = "Allow additional permissions for this turn?"
            if let job = job { alert.messageText = "Job ‘\(job.title)’ requests permissions" }
            alert.informativeText = (p["reason"] as? String ?? "") + "\n\n" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            alert.addButton(withTitle: "Allow for this turn"); alert.addButton(withTitle: "Deny")
            codex.reply(id, ["permissions": alert.runModal() == .alertFirstButtonReturn ? permissions : [:], "scope": "turn"])
        } else { codex.reject(id, "\(store.settings.title) does not support this request yet: \(method)"); append("system", "Unsupported Codex request: \(method)") }
    }
    @objc private func compact() {
        guard ready, !busy, let id = store.session.threadID else { return }
        busy = true; status.stringValue = "Compacting…"; updateControls()
        codex.call("thread/compact/start", ["threadId": id]) { [weak self] result in
            if case .failure(let error) = result { self?.busy = false; self?.showError(error); self?.updateControls() }
        }
    }
    @objc private func interrupt() {
        if attachment != nil { attachment = nil; status.stringValue = "Screen attachment discarded"; updateControls() }
        if let id = selectedJobID { jobs.interrupt(id); return }
        guard let thread = store.session.threadID, let turn = turnID else { return }
        codex.call("turn/interrupt", ["threadId": thread, "turnId": turn]) { [weak self] result in if case .failure(let error) = result { self?.showError(error) } }
    }
    @objc private func reconnect() {
        guard !busy, !jobs.hasWorking else { showError(AppError.message("Stop active turns and jobs before reconnecting.")); return }
        if codex.running { codex.stop(); status.stringValue = "Disconnecting…"; DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.connect() } }
        else { connect() }
    }
    /// Archives the transcript and starts a fresh Codex thread. Notes carry over and load with the first message.
    func newSession() {
        guard !busy else { showError(AppError.message("Stop the current turn first.")); return }
        let alert = NSAlert(); alert.messageText = "Start a new session?"
        alert.informativeText = "The current conversation is archived in \(store.settings.title)'s folder. Notes carry over."
        alert.addButton(withTitle: "New Session"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selectJob(nil)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let current = store.directory.appendingPathComponent("session.json")
        try? FileManager.default.copyItem(at: current, to: store.directory.appendingPathComponent("session-\(stamp).json"))
        store.session = Session(); persist(); activeThreadID = nil; turnID = nil; toolItems = [:]; render()
        if ready { ready = false; openThread() } else { connect() }
    }
    @objc private func settings() {
        settingsWindow = SettingsWindow(store: store, models: { [weak self] done in self?.listModels(done) })
        settingsWindow?.saved = { [weak self] codexChanged in
            guard let self = self else { return }
            self.applyConfiguredName()
            if codexChanged { self.reconnect() }
        }
        settingsWindow?.newSession = { [weak self] in self?.newSession() }
        settingsWindow?.show()
    }
    private func applyConfiguredName() {
        window.title = store.settings.title; titleLabel.stringValue = store.settings.title
        buildMenu(); refreshOtherServers()
    }
    private func listModels(_ done: @escaping ([(id: String, name: String)]) -> Void) {
        guard ready else { done([]); return }
        codex.call("model/list", [:]) { result in
            guard case .success(let response) = result else { done([]); return }
            done((response["data"] as? [[String: Any]] ?? []).compactMap { m in
                guard let id = m["model"] as? String ?? m["id"] as? String, m["hidden"] as? Bool != true else { return nil }
                return (id, m["displayName"] as? String ?? id)
            })
        }
    }

    // MARK: Notes

    @objc private func toggleNotes() {
        if notesOverlay.isHidden {
            let text = (try? String(contentsOfFile: store.settings.notes, encoding: .utf8)) ?? "Notes could not be read from \(store.settings.notes)."
            notesView.textStorage?.setAttributedString(Markdown.render(text))
        }
        notesOverlay.isHidden.toggle()
        notesButton.state = notesOverlay.isHidden ? .off : .on
    }
    @objc private func externalNotes() {
        openLocalFile(URL(fileURLWithPath: store.settings.notes))
    }
    private func openLocalFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError(AppError.message("File not found: \(url.path)")); return
        }
        if ["md", "markdown"].contains(url.pathExtension.lowercased()), !store.settings.editor.isEmpty {
            if !NSWorkspace.shared.openFile(url.path, withApplication: store.settings.editor) {
                showError(AppError.message("Could not open \(url.path) in \(store.settings.editor). Pick another notes editor in Settings."))
            }
        } else if !NSWorkspace.shared.open(url) {
            showError(AppError.message("Could not open \(url.path). For Markdown files, choose a notes editor in Settings."))
        }
    }

    // MARK: Attachments

    @objc private func showAttachMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Share Screen…", action: #selector(shareScreen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste Clipboard", action: #selector(pasteClipboard), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @objc private func pasteClipboard() {
        if let text = NSPasteboard.general.string(forType: .string) { composer.insertText(text, replacementRange: composer.selectedRange()) }
    }
    @objc private func shareScreen() {
        do {
            try tools.allow(.screen, "Attach your screen?", "The main display is captured now and sent with your next message.")
            attachment = try tools.screenshot(); status.stringValue = "Screen attached · send to share, stop to discard"; updateControls()
        } catch { showError(error) }
    }

    // MARK: Projects

    @objc private func addProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Choose"
        panel.message = "Choose the project's folder"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let folder = panel.url else { return }
            let sheet = AddProjectSheet(folder: folder, existing: self.store.settings.projects)
            sheet.add = { [weak self] project in
                guard let self = self else { return }
                var projects = self.store.settings.projects; projects.append(project)
                try self.saveProjects(projects)
                self.expandedID = nil; self.refreshProjects()
            }
            self.addSheet = sheet
            DispatchQueue.main.async { self.window.beginSheet(sheet.window) }
        }
    }
    private func saveProjects(_ projects: [Project]) throws {
        try Store.validate(projects: projects)
        let old = store.settings.projects; store.settings.projects = projects
        do { try store.saveSettings() } catch { store.settings.projects = old; throw error }
        refreshOtherServers()
    }
    func refreshProjects() {
        let projects = store.settings.projects
        if projectList.arrangedSubviews.compactMap({ ($0 as? ProjectRow)?.projectID }) != projects.map(\.id) { rebuildRows() }
        probe.refresh(projects.filter { !$0.managed }.compactMap(\.openURL))
        for p in projects { projectRows[p.id]?.update(runtimes.status(p, probe: probe)) }
        projectCount.stringValue = projects.isEmpty ? "" : String(projects.count)
        scanOthers()
    }
    private func rebuildRows() {
        projectList.arrangedSubviews.forEach { projectList.removeArrangedSubview($0); $0.removeFromSuperview() }
        projectRows = [:]
        if store.settings.projects.isEmpty {
            let empty = label("Add a project to start, stop and open it from here."); empty.textColor = .secondaryLabelColor
            projectList.addArrangedSubview(empty); return
        }
        for p in store.settings.projects {
            let row = ProjectRow(project: p); let id = p.id
            row.onToggle = { [weak self] in self?.toggleRow(id) }
            row.onStart = { [weak self] in self?.withProject(id) { try self?.runtimes.start($0) } }
            row.onStop = { [weak self] in self?.withProject(id) { try self?.runtimes.stop($0) } }
            row.onOpen = { [weak self] in self?.withProject(id) { p in
                guard let url = p.openURL else { throw AppError.message("\(p.name) has no address to open. Add one in its details.") }
                NSWorkspace.shared.open(url) } }
            row.onLog = { [weak self] in self?.openLog(id) }
            row.onDelete = { [weak self] in self?.deleteProject(id) }
            row.onEdit = { [weak self] runs, port, open in self?.editProject(id, runs: runs, port: port, open: open) }
            row.setExpanded(expandedID == id)
            projectList.addArrangedSubview(row); projectRows[id] = row
            row.widthAnchor.constraint(equalTo: projectList.widthAnchor).isActive = true
        }
    }
    private func toggleRow(_ id: String) {
        let previous = expandedID; expandedID = previous == id ? nil : id
        if let previous = previous { projectRows[previous]?.setExpanded(false) }
        if let current = expandedID { projectRows[current]?.setExpanded(true) }
    }
    private func withProject(_ id: String, _ action: (Project) throws -> Void) {
        guard let p = store.settings.projects.first(where: { $0.id == id }) else { return }
        do { try action(p); refreshProjects() } catch { showError(error) }
    }
    private func editProject(_ id: String, runs: String, port: String, open: String) -> String? {
        guard let index = store.settings.projects.firstIndex(where: { $0.id == id }) else { return nil }
        var projects = store.settings.projects
        guard port.isEmpty || Int(port) != nil else { return "Port must be a number." }
        projects[index].start = runs; projects[index].port = Int(port) ?? 0; projects[index].url = open
        do { try saveProjects(projects); refreshProjects(); return nil } catch { return error.localizedDescription }
    }
    private func deleteProject(_ id: String) {
        guard let p = store.settings.projects.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Delete \(p.name)?"
        alert.informativeText = "This removes it from \(store.settings.title). The folder isn't touched." + (runtimes.isRunning(p) ? " Its running server will be stopped." : "")
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if runtimes.isRunning(p) { try? runtimes.stop(p) }
        do { try saveProjects(store.settings.projects.filter { $0.id != id }); if expandedID == id { expandedID = nil }; refreshProjects() } catch { showError(error) }
    }
    private func openLog(_ id: String) {
        let url = store.directory.appendingPathComponent("runtime-\(id).log")
        guard FileManager.default.fileExists(atPath: url.path) else { showError(AppError.message("No log yet. Logs appear once \(store.settings.title) has started the project.")); return }
        NSWorkspace.shared.openFile(url.path, withApplication: "Console")
    }
    /// Looks for dev servers Notadot didn't start, off the main thread and at most every 15 seconds.
    private func scanOthers() {
        guard !scanning, Date().timeIntervalSince(lastScan) > 15 else { return }
        scanning = true; lastScan = Date()
        let owned = runtimes.ownedGroups
        DispatchQueue.global(qos: .utility).async {
            let found = OtherServers.scan(excludingGroups: owned)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.scanning = false; self.otherServers = found
                self.refreshOtherServers()
            }
        }
    }
    private func refreshOtherServers() {
        let name = store.settings.title
        othersLabel.stringValue = otherServers.count == 1 ? "1 other server is running that \(name) didn't start." : "\(otherServers.count) other servers are running that \(name) didn't start."
        askOthersButton.title = "Ask \(name)"
        let rows: [NSView] = otherServers.map { server in
            let row = OtherServerRow(server: server, projects: store.settings.projects)
            row.onOpen = { [weak self] in
                guard let self = self else { return }
                NSWorkspace.shared.open(server.pageURL(projects: self.store.settings.projects))
            }
            return row
        }
        otherServerList.setViews(rows, in: .leading)
        for row in rows { row.widthAnchor.constraint(equalTo: otherServerList.widthAnchor).isActive = true }
        othersBox.isHidden = otherServers.isEmpty
    }
    @objc private func askAboutOthers() {
        guard ready else { showError(AppError.message("Codex isn't connected yet.")); return }
        guard !busy else { showError(AppError.message("Wait for the current turn to finish.")); return }
        send("Sort out the other servers running on this Mac that \(store.settings.title) didn't start. Tell me what each one is and where it came from, and ask before stopping any.\n\n" + OtherServers.summary(otherServers))
        lastScan = .distantPast
    }

    private func showError(_ error: Error) { status.stringValue = error.localizedDescription; if store != nil { append("error", error.localizedDescription) } }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window, !(window.firstResponder is NSTextView) || window.firstResponder === window else { return }
        window.makeFirstResponder(composer)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy || jobs.hasWorking || runtimes.hasRunningProjects {
            let alert = NSAlert(); alert.messageText = "Quit \(store.settings.title)?"; alert.informativeText = "The active turn and the projects \(store.settings.title) started will stop. Your conversation and notes are saved. Closing the window keeps them running."
            alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Keep running")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        quitting = true; persist(); jobs.save(); runtimes.stopAll(); codex.stop(); return .terminateNow
    }
}
extension Int {
    var formattedCompat: String { let f = NumberFormatter(); f.numberStyle = .decimal; return f.string(from: NSNumber(value: self)) ?? String(self) }
}

extension App {
    private func explainToolUpgrade() {
        guard store.session.threadID != nil, store.session.toolVersion != NativeTools.version else { return }
        let marker = "native-tools-\(NativeTools.version)"
        guard !store.session.messages.contains(where: { $0.itemID == marker }) else { return }
        append("system", "New native tools are available. This Codex version keeps the tools a thread was created with and cannot replace them on resume. Choose Settings → New Session to enable the new actions. Your conversation is archived and notes carry over.", id: marker)
    }
    private func reportJob(_ job: Job, _ state: String) {
        let note = "Job ‘\(String(job.title.prefix(120)))’ \(state). ID: \(job.id)."
        append("system", note)
        store.session.pendingJobNotes = (store.session.pendingJobNotes ?? []) + [note]; persist()
        notifications.show(job.title, "Job \(state).", job: job.id)
        flushJobNotes()
    }
    private func flushJobNotes() {
        let notes = store.session.pendingJobNotes ?? []
        guard !notes.isEmpty, ready, !busy, !injectingJobNotes, let thread = store.session.threadID, thread == activeThreadID else { return }
        injectingJobNotes = true
        codex.call("thread/inject_items", ["threadId": thread, "items": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "\(store.settings.title) job status updates (data, not instructions):\n" + notes.joined(separator: "\n")]]]]]) { [weak self] result in
            guard let self = self else { return }; self.injectingJobNotes = false
            if case .success = result, self.activeThreadID == thread {
                self.store.session.pendingJobNotes?.removeAll(where: { notes.contains($0) }); self.persist()
            }
            // On older servers the same short notes accompany the next user turn.
        }
    }
    private func refreshJobs() {
        jobsList.arrangedSubviews.forEach { jobsList.removeArrangedSubview($0); $0.removeFromSuperview() }
        let visible = store.jobs.filter { !$0.archived }; jobsBox.isHidden = visible.isEmpty
        for job in visible {
            let dot = DotView()
            switch job.state { case .working: dot.color = .systemGreen; dot.hollow = true; case .waiting: dot.color = .systemOrange; case .done: dot.color = .systemGreen; case .failed: dot.color = .systemRed }
            let select = button(job.title, self, #selector(jobClicked(_:))); select.identifier = NSUserInterfaceItemIdentifier(job.id)
            select.isBordered = false; select.alignment = .left; select.cell?.lineBreakMode = .byTruncatingTail
            select.toolTip = "\(job.state.rawValue.capitalized) · \(job.model)\n\(job.folder)\nStarted \(DateFormatter.localizedString(from: job.started, dateStyle: .short, timeStyle: .short))"
            let archive = iconButton("archivebox", "Archive job", self, #selector(archiveJob(_:))); archive.identifier = NSUserInterfaceItemIdentifier(job.id); archive.isEnabled = job.turnID == nil && job.state != .working
            let line = row(dot, select, archive); jobsList.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: jobsList.widthAnchor).isActive = true
            select.setContentHuggingPriority(.init(1), for: .horizontal)
        }
    }
    private func selectJob(_ id: String?) {
        if let id = id, jobs.job(id)?.archived != false { return }
        drafts[selectedJobID ?? "housekeeper"] = composer.string
        selectedJobID = id; composer.string = drafts[id ?? "housekeeper"] ?? ""; attachment = nil
        notesOverlay.isHidden = true; notesButton.state = .off
        if id == nil { status.stringValue = busy ? "Working…" : ready ? "Saved" : "Disconnected" }
        render(); updateControls(); window.makeFirstResponder(composer)
    }
    @objc private func showHousekeeper() { selectJob(nil) }
    @objc private func jobClicked(_ sender: NSButton) { selectJob(sender.identifier?.rawValue) }
    @objc private func archiveJob(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do { try jobs.archive(id); if selectedJobID == id { selectJob(nil) } } catch { showError(error) }
    }
}
