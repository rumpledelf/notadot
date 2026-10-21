import AppKit

struct Job: Codable {
    enum State: String, Codable { case working, waiting, done, failed }
    var id = UUID().uuidString
    var title: String
    var folder: String
    var model: String
    var task: String
    var started = Date()
    var threadID: String?
    var state: State = .working
    var archived = false
    var messages: [Message] = []
    var turnID: String?
    var latestReply: String { messages.last(where: { $0.role == "assistant" })?.text ?? "No reply yet." }
}

final class Jobs {
    let store: Store, codex: Codex
    var changed: (() -> Void)?
    var report: ((Job, String) -> Void)?
    var persistenceError: ((Error) -> Void)?
    private var loaded = Set<String>()
    private var loading = Set<String>()
    private var liveThreads: [String: String] = [:]
    init(store: Store, codex: Codex) { self.store = store; self.codex = codex }
    var hasWorking: Bool { store.jobs.contains { $0.state == .working || $0.turnID != nil } }
    func job(_ id: String) -> Job? { store.jobs.first { $0.id == id || $0.threadID == id || liveThreads[$0.id] == id } }
    private func index(_ id: String) -> Int? { store.jobs.firstIndex { $0.id == id } }
    func save() { do { try store.saveJobs() } catch { persistenceError?(error) }; changed?() }
    static func folder(_ raw: String, projects: [Project]) throws -> String {
        guard raw.hasPrefix("/") else { throw AppError.message("A job folder must be an absolute project path.") }
        let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw AppError.message("The job folder does not exist.") }
        guard projects.contains(where: {
            let root = URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path
            return url.path == root || url.path.hasPrefix(root + "/")
        }) else { throw AppError.message("Choose one of your configured project folders, or a folder inside it.") }
        return url.path
    }
    func perform(_ args: [String: Any], completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        func answer(_ text: String) { completion(.success([["type": "inputText", "text": text]])) }
        do {
            switch args["action"] as? String ?? "" {
            case "job_start":
                let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let task = (args["task"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let folder = try Self.folder(args["folder"] as? String ?? "", projects: store.settings.projects)
                guard !title.isEmpty, !task.isEmpty else { throw AppError.message("Provide a job title and task.") }
                let model = store.settings.jobsModel
                guard !model.isEmpty else { throw AppError.message("Choose a Jobs model in Settings first.") }
                codex.call("model/list", [:]) { [weak self] result in
                    guard let self = self else { return }
                    do {
                        let catalog = try result.get()["data"] as? [[String: Any]] ?? []
                        guard catalog.contains(where: { ($0["model"] as? String ?? $0["id"] as? String) == model }) else { throw AppError.message("The selected Jobs model is unavailable. Choose it again in Settings.") }
                        let alert = NSAlert(); alert.messageText = "Start job ‘\(title)’?"
                        alert.informativeText = "Folder: \(folder)\nModel: \(model)\n\n\(task)"
                        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220)); view.string = alert.informativeText; view.isEditable = false; view.font = .systemFont(ofSize: 13)
                        let scroll = NSScrollView(frame: view.frame); scroll.hasVerticalScroller = true; scroll.documentView = view
                        alert.informativeText = "Review the job before it uses the selected model."; alert.accessoryView = scroll
                        alert.addButton(withTitle: "Allow Once"); alert.addButton(withTitle: "Don't Allow")
                        guard alert.runModal() == .alertFirstButtonReturn else { throw AppError.message("User declined the job.") }
                        let job = Job(title: title, folder: folder, model: model, task: task)
                        self.store.jobs.append(job); self.save()
                        self.send(job.id, task) { result in
                            switch result { case .success: answer("Job started: \(job.id) · \(title)"); case .failure(let error): completion(.failure(error)) }
                        }
                    } catch { completion(.failure(error)) }
                }
            case "job_list":
                let rows: [[String: Any]] = store.jobs.filter { !$0.archived }.map { ["id": $0.id, "title": $0.title, "folder": $0.folder, "model": $0.model, "status": $0.state.rawValue, "started": ISO8601DateFormatter().string(from: $0.started)] }
                answer(String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8) ?? "[]")
            case "job_result", "job_message":
                let name = args["job"] as? String ?? ""
                let matches = store.jobs.filter { $0.id == name || $0.title == name }
                guard matches.count == 1, let job = matches.first else { throw AppError.message("Use a unique job ID from job_list.") }
                if args["action"] as? String == "job_result" { answer("\(job.title) · \(job.state.rawValue)\n" + job.latestReply); return }
                let text = args["text"] as? String ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("Provide follow-up text.") }
                guard !job.archived else { throw AppError.message("That job is archived.") }
                send(job.id, text) { result in switch result { case .success: answer("Message sent to \(job.title)."); case .failure(let error): completion(.failure(error)) } }
            default: throw AppError.message("Unknown job action.")
            }
        } catch { completion(.failure(error)) }
    }
    func resumeAll() {
        for job in store.jobs where !job.archived {
            if job.threadID != nil { load(job.id) { _ in } }
            else if let i = index(job.id) { store.jobs[i].state = .failed; store.jobs[i].turnID = nil }
        }
        save()
    }
    private func load(_ id: String, done: @escaping (Result<Void, Error>) -> Void) {
        guard let job = job(id), !loading.contains(id) else { done(.failure(AppError.message("Job is reconnecting; try again shortly."))); return }
        if loaded.contains(id) { done(.success(())); return }
        loading.insert(id)
        var params: [String: Any] = ["cwd": job.folder, "runtimeWorkspaceRoots": [job.folder], "model": job.model, "sandbox": "workspace-write", "approvalPolicy": "on-request", "approvalsReviewer": "user", "developerInstructions": "Work on the user's approved job in this project. Ask the user when a decision or approval is needed. When waiting for feedback, use request_user_input so the app knows you are waiting. Do not launch more jobs, access reminders/email, or act as the housekeeper."]
        let method: String
        if let thread = job.threadID { params["threadId"] = thread; method = "thread/resume" }
        else {
            method = "thread/start"; params["dynamicTools"] = [[String: Any]]()
            params["config"] = ["features.multi_agent": false, "apps._default.enabled": false]
        }
        codex.call(method, params) { [weak self] result in
            guard let self = self, let i = self.index(id) else { return }; self.loading.remove(id)
            do {
                let result = try result.get()
                guard let thread = result["thread"] as? [String: Any], let threadID = thread["id"] as? String else { throw AppError.message("Codex returned no job thread ID.") }
                self.liveThreads[id] = threadID; self.store.jobs[i].turnID = nil
                var active = false
                for turn in thread["turns"] as? [[String: Any]] ?? [] {
                    for item in turn["items"] as? [[String: Any]] ?? [] where item["type"] as? String == "agentMessage" { self.agent(i, item) }
                    if turn["status"] as? String == "inProgress" { active = true; self.store.jobs[i].turnID = turn["id"] as? String }
                }
                if !active && self.store.jobs[i].state == .working { self.store.jobs[i].state = .waiting }
                self.loaded.insert(id); self.save(); done(.success(()))
            } catch { self.fail(id, error); done(.failure(error)) }
        }
    }
    func send(_ id: String, _ text: String, attachment: String? = nil, done: @escaping (Result<Void, Error>) -> Void) {
        load(id) { [weak self] result in
            guard let self = self else { return }
            do { try result.get() } catch { done(.failure(error)); return }
            guard let i = self.index(id), let thread = self.liveThreads[id] ?? self.store.jobs[i].threadID else { done(.failure(AppError.message("Job could not be loaded."))); return }
            var input: [[String: Any]] = [["type": "text", "text": text]]
            if let attachment = attachment { input.append(["type": "image", "url": attachment]) }
            var params: [String: Any] = ["threadId": thread, "input": input]
            let steer = self.store.jobs[i].turnID != nil
            if let turn = self.store.jobs[i].turnID { params["expectedTurnId"] = turn }
            self.store.jobs[i].messages.append(Message(role: "you", text: text)); self.store.jobs[i].state = .working; self.save()
            self.codex.call(steer ? "turn/steer" : "turn/start", params) { result in
                do {
                    let response = try result.get()
                    self.store.jobs[i].threadID = thread
                    if let turn = response["turn"] as? [String: Any] { self.store.jobs[i].turnID = turn["id"] as? String }
                    self.save(); done(.success(()))
                } catch { self.fail(id, error); done(.failure(error)) }
            }
        }
    }
    func event(_ method: String, _ params: [String: Any]) -> Bool {
        guard let thread = params["threadId"] as? String, let i = store.jobs.firstIndex(where: { $0.threadID == thread || liveThreads[$0.id] == thread }) else { return false }
        switch method {
        case "turn/started": store.jobs[i].threadID = thread; store.jobs[i].state = .working; store.jobs[i].turnID = (params["turn"] as? [String: Any])?["id"] as? String
        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return true }
            if let j = store.jobs[i].messages.firstIndex(where: { $0.itemID == id }) { store.jobs[i].messages[j].text += delta }
            else { store.jobs[i].messages.append(Message(role: "assistant", text: delta, itemID: id)) }
            changed?(); return true // Checkpoint deltas on the app timer, not for every token.
        case "item/completed":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" { agent(i, item) }
        case "item/started":
            if let item = params["item"] as? [String: Any], let kind = item["type"] as? String,
               ["commandExecution", "fileChange", "mcpToolCall", "webSearch"].contains(kind) {
                store.jobs[i].messages.append(Message(role: "tool", text: String((item["command"] as? String ?? kind).prefix(1500)), itemID: item["id"] as? String))
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String ?? "failed"
            store.jobs[i].turnID = nil; store.jobs[i].state = status == "completed" ? .done : status == "interrupted" ? .waiting : .failed
            if let error = turn["error"] as? [String: Any] { store.jobs[i].messages.append(Message(role: "error", text: error["message"] as? String ?? "Job failed.")) }
            report?(store.jobs[i], status == "completed" ? "finished" : status == "interrupted" ? "is waiting for you" : "failed")
        default: return true
        }
        save(); return true
    }
    private func agent(_ i: Int, _ item: [String: Any]) {
        guard let id = item["id"] as? String, let text = item["text"] as? String else { return }
        if let j = store.jobs[i].messages.firstIndex(where: { $0.itemID == id }) { store.jobs[i].messages[j].text = text }
        else { store.jobs[i].messages.append(Message(role: "assistant", text: text, itemID: id)) }
    }
    func waiting(_ id: String) {
        guard let i = index(id), store.jobs[i].state != .waiting else { return }
        store.jobs[i].state = .waiting; save(); report?(store.jobs[i], "is waiting for you")
    }
    func approvalResolved(_ id: String) { if let i = index(id), store.jobs[i].turnID != nil { store.jobs[i].state = .working; save() } }
    func archive(_ id: String) throws {
        guard let i = index(id), store.jobs[i].turnID == nil, store.jobs[i].state != .working else { throw AppError.message("Stop the job before archiving it.") }
        store.jobs[i].archived = true; try store.saveJobs(); changed?()
    }
    func interrupt(_ id: String) {
        guard let job = job(id), let thread = job.threadID, let turn = job.turnID else { return }
        codex.call("turn/interrupt", ["threadId": thread, "turnId": turn]) { [weak self] result in if case .failure(let error) = result { self?.fail(id, error) } }
    }
    func disconnected() {
        loaded.removeAll(); loading.removeAll(); liveThreads.removeAll()
        for i in store.jobs.indices where store.jobs[i].state == .working || store.jobs[i].turnID != nil { store.jobs[i].state = .waiting; store.jobs[i].turnID = nil }
        save()
    }
    private func fail(_ id: String, _ error: Error) {
        guard let i = index(id) else { return }; store.jobs[i].state = .failed; store.jobs[i].turnID = nil
        store.jobs[i].messages.append(Message(role: "error", text: error.localizedDescription)); save()
    }
}
