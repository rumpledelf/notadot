import Foundation

final class Codex {
    var event: ((String, [String: Any]) -> Void)?
    var request: ((Any, String, [String: Any]) -> Void)?
    var disconnected: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var methods: [Int: String] = [:]
    var running: Bool { process?.isRunning == true }

    func start(path: String, cwd: String, ready: @escaping (Result<[String: Any], Error>) -> Void) throws {
        guard !running else { throw AppError.message("Codex is already connected.") }
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["app-server", "--listen", "stdio://"]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin", "/opt/homebrew/bin", "/opt/local/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        // Drain stderr continuously so a verbose child can never block on a full pipe.
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] proc in DispatchQueue.main.async {
            guard let self = self, self.process === proc else { return }
            self.closed("Codex exited (\(proc.terminationStatus)). Reconnect to resume.")
        } }
        process = p
        do { try p.run() } catch { closed(error.localizedDescription); throw error }
        call("initialize", ["clientInfo": ["name": "notadot", "title": "Notadot", "version": "0.1.0"], "capabilities": ["experimentalApi": true]]) { [weak self] result in
            if case .success = result { self?.send(["method": "initialized", "params": [:]]) }
            ready(result)
        }
    }
    func call(_ method: String, _ params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard running else { completion(.failure(AppError.message("Codex is disconnected."))); return }
        nextID += 1; pending[nextID] = completion; methods[nextID] = method
        send(["id": nextID, "method": method, "params": params])
    }
    func reply(_ id: Any, _ result: [String: Any]) { send(["id": id, "result": result]) }
    func reject(_ id: Any, _ message: String) { send(["id": id, "error": ["code": -32601, "message": message]]) }
    private func send(_ object: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            guard let handle = input else { throw AppError.message("Codex input is closed.") }
            try handle.write(contentsOf: data)
        } catch { closed(error.localizedDescription) }
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if let method = object["method"] as? String {
                let params = object["params"] as? [String: Any] ?? [:]
                if let id = object["id"] { request?(id, method, params) } else { event?(method, params) }
            } else if let id = object["id"] as? Int, let completion = pending.removeValue(forKey: id) {
                let method = methods.removeValue(forKey: id) ?? "request"
                // Name the method so a protocol change in a Codex update is recognisable as one.
                if let error = object["error"] as? [String: Any] { completion(.failure(AppError.message("Codex \(method): " + (error["message"] as? String ?? "request failed.")))) }
                else { completion(.success(object["result"] as? [String: Any] ?? [:])) }
            }
        }
    }
    private func closed(_ message: String) {
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        input = nil; buffer = Data()
        let callbacks = pending.values; pending.removeAll(); methods.removeAll()
        callbacks.forEach { $0(.failure(AppError.message(message))) }
        disconnected?(message)
    }
    func stop() { output?.readabilityHandler = nil; errors?.readabilityHandler = nil; if running { process?.terminate() }; input = nil }
}
