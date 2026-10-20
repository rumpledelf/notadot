import Foundation

/// Remembers whether each project URL answered recently. Any HTTP response counts: the point is
/// "something is there", not "it works". Checks run off the main thread and are throttled per URL.
final class URLProbe {
    private var results: [URL: Bool] = [:]
    private var checked: [URL: Date] = [:]
    var changed: (() -> Void)?
    func result(_ url: URL) -> Bool? { results[url] }
    func refresh(_ urls: [URL], every interval: TimeInterval = 15) {
        for url in urls where Date().timeIntervalSince(checked[url] ?? .distantPast) > interval {
            checked[url] = Date()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            request.httpMethod = "HEAD"
            URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
                DispatchQueue.main.async {
                    let answered = response is HTTPURLResponse
                    if self?.results[url] != answered { self?.results[url] = answered; self?.changed?() }
                }
            }.resume()
        }
    }
}

/// Dev servers listening on this Mac that Notadot didn't start. Notadot never stops these itself;
/// the list is handed to the chat so the assistant can sort them out with the user.
struct OtherServer { let pid: Int32; let command: String; let port: Int; let folder: String }
enum OtherServers {
    static let devCommands: Set<String> = ["node", "php", "python", "python3", "Python", "ruby", "java", "deno", "bun", "go", "hugo", "beam.smp", "uvicorn", "gunicorn", "rails", "puma"]
    static func scan(excludingGroups owned: Set<Int32>) -> [OtherServer] {
        let output = RuntimeManager.command("/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpcgn"])
        var found: [OtherServer] = []; var seen = Set<String>()
        var pid: Int32 = 0, group: Int32 = 0, command = ""
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value) ?? 0
            case "g": group = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard devCommands.contains(command), !owned.contains(group), let port = Int(value.split(separator: ":").last ?? ""), seen.insert("\(pid):\(port)").inserted else { continue }
                found.append(OtherServer(pid: pid, command: command, port: port, folder: folder(of: pid)))
            default: break
            }
        }
        return found.sorted { $0.port < $1.port }
    }
    static func folder(of pid: Int32) -> String {
        let output = RuntimeManager.command("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        let path = output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? "?"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
    static func summary(_ servers: [OtherServer]) -> String {
        servers.map { "- \($0.command) (pid \($0.pid)) on :\($0.port) in \($0.folder)" }.joined(separator: "\n")
    }
}
