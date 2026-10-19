import AppKit
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--self-test") {
    do { try selfTest(); exit(0) } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App()
app.delegate = delegate
app.run()
