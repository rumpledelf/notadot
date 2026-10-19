import Foundation
import Darwin

final class RuntimeManager {
    struct Running { let process: Process; let port: Int; let log: URL; let started: Date }
    private var running: [String: Running] = [:]
    private var failures: [String: String] = [:]
    let directory: URL
    init(directory: URL) { self.directory = directory }
    static func command(_ path: String, _ arguments: [String]) -> String {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(data: data, encoding: .utf8) ?? "" } catch { return "" }
    }
    static func portOccupied(_ port: Int) -> Bool {
        // Probe IPv4 and IPv6. Never choose another port or terminate its current owner.
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var result: Int32 = 0
            if family == AF_INET {
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
                result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var address = sockaddr_in6(); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6); address.sin6_port = UInt16(port).bigEndian
                result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            let code = errno; close(fd)
            if result != 0 && code == EADDRINUSE { return true }
        }
        return false
    }
    func status(_ project: Project) -> String {
        if let run = running[project.id] {
            if !run.process.isRunning { running.removeValue(forKey: project.id); failures[project.id] = "Exited (\(run.process.terminationStatus)); see log" }
            else {
                let listeners = Self.command("/usr/sbin/lsof", ["-nP", "-a", "-g", String(run.process.processIdentifier), "-iTCP", "-sTCP:LISTEN", "-Fn"])
                let ports = listeners.split(separator: "\n").filter { $0.hasPrefix("n") }.compactMap { Int($0.split(separator: ":").last ?? "") }
                if ports.contains(where: { $0 != run.port }) {
                    terminate(project.id); failures[project.id] = "Stopped: runtime opened an unconfigured port"; return failures[project.id]!
                }
                if ports.contains(run.port) { return "Running · :\(run.port)" }
                if Date().timeIntervalSince(run.started) > 30 {
                    terminate(project.id); failures[project.id] = "Failed: port \(run.port) did not open within 30 seconds"; return failures[project.id]!
                }
                return "Starting · :\(run.port)"
            }
        }
        if let error = failures[project.id] { return error }
        return Self.portOccupied(project.port) ? "Port \(project.port) occupied · unmanaged" : "Stopped"
    }
    func start(_ project: Project) throws {
        guard running[project.id]?.process.isRunning != true else { return }
        guard !Self.portOccupied(project.port) else { throw AppError.message("Port \(project.port) is occupied. Nothing was stopped and no alternative port was chosen.") }
        guard project.start.contains("{port}") else { throw AppError.message("The start command must contain {port}, with strict-port mode if the server supports it.") }
        let log = directory.appendingPathComponent("runtime-\(project.id).log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        // setsid makes a private process group so Stop reaches the shell and its children.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MPOSIX", "-e", "getpgrp(0) == $$ || POSIX::setsid() >= 0 or die $!; exec @ARGV or die $!", "/bin/bash", "-lc", project.start.replacingOccurrences(of: "{port}", with: String(project.port))]
        process.currentDirectoryURL = URL(fileURLWithPath: project.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(project.port)
        environment["PATH"] = "/opt/local/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment; process.standardOutput = handle; process.standardError = handle
        try process.run(); try? handle.close()
        running[project.id] = Running(process: process, port: project.port, log: log, started: Date()); failures.removeValue(forKey: project.id)
    }
    func stop(_ project: Project) throws {
        guard running[project.id]?.process.isRunning == true else { throw AppError.message("This app does not own a running process for \(project.name). It will not stop an unrelated listener.") }
        // A configured stop command runs only for an app-owned runtime.
        if !project.stop.isEmpty {
            let command = project.stop.replacingOccurrences(of: "{port}", with: String(project.port))
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-lc", command]; p.currentDirectoryURL = URL(fileURLWithPath: project.path)
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run() // Do not block the app on an arbitrary stop script.
        }
        terminate(project.id); failures.removeValue(forKey: project.id)
    }
    private func terminate(_ id: String) {
        guard let run = running.removeValue(forKey: id), run.process.isRunning else { return }
        kill(-run.process.processIdentifier, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // The leader may exit before one of its children. The private group
            // remains addressable until the last child exits.
            if kill(-run.process.processIdentifier, 0) == 0 { kill(-run.process.processIdentifier, SIGKILL) }
        }
    }
    func stopAll() {
        let groups = running.values.filter { $0.process.isRunning }.map { $0.process.processIdentifier }
        for id in Array(running.keys) { terminate(id) }
        // Quit ends the main run loop, so its delayed cleanup cannot be relied on.
        if !groups.isEmpty {
            usleep(200000)
            for group in groups where kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        }
    }
    var hasRunningProjects: Bool { running.values.contains { $0.process.isRunning } }
}
