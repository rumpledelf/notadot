import AppKit
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--self-test") {
    do { try selfTest(); exit(0) } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--assistant-contract") {
    let path = "/tmp/notadot-behavior-notes.md"
    let contract: [String: Any] = ["instructions": Housekeeper.instructions(name: "Notadot", notes: path), "tools": NativeTools.definitions, "notes": Housekeeper.notesBlock(path: path, contents: "# Notes\nProject ports are fixed. Never choose another port automatically.")]
    do { let data = try JSONSerialization.data(withJSONObject: contract); print(String(data: data, encoding: .utf8)!); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App()
app.delegate = delegate
app.run()
