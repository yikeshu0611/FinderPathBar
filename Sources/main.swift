import AppKit

if CommandLine.arguments.contains("--watch-agent")
    || Bundle.main.bundleIdentifier == "com.zhangjing.NewFinder.Watch" {
    WatchAgentMain.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Agent-style: no Dock icon; status item lives in the menu bar.
    app.setActivationPolicy(.accessory)
    app.run()
}
