import AppKit

/// Always-on helper process (`NewFinderWatch` / `NewFinder --watch-agent`).
/// Uses a separate bundle ID so Launch Services does not treat it as the UI app.
/// When the UI instance is not running and Finder is activated (e.g. Dock click),
/// close Finder windows immediately and relaunch NewFinder with `--steal-finder`.
enum WatchAgentMain {
    static func run() {
        let app = NSApplication.shared
        let delegate = WatchAgentDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }

    /// Parent `NewFinder.app` whether we run as nested helper or `--watch-agent` inside UI app.
    static func uiAppURL() -> URL {
        let bundle = Bundle.main.bundleURL
        if Bundle.main.bundleIdentifier == "com.zhangjing.NewFinder.Watch" {
            // …/NewFinder.app/Contents/Helpers/NewFinderWatch.app
            return bundle
                .deletingLastPathComponent() // Helpers
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // NewFinder.app
        }
        return bundle
    }
}

private final class WatchAgentDelegate: NSObject, NSApplicationDelegate {
    private var lastLaunchAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleFinderNote(note)
        }
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleFinderNote(note)
        }
    }

    private func handleFinderNote(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.finder" else { return }
        guard !isUIInstanceRunning() else { return }
        if let last = lastLaunchAt, Date().timeIntervalSince(last) < 1.0 { return }
        lastLaunchAt = Date()

        closeFinderWindows()
        launchUIInstance()
    }

    /// True when the NewFinder UI app is running.
    private func isUIInstanceRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.zhangjing.NewFinder"
                && !$0.isTerminated
        }
    }

    private func closeFinderWindows() {
        let source = """
        tell application "Finder"
          try
            close every window
          end try
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private func launchUIInstance() {
        // Do not use `open -n` — that spawned duplicate UI windows/processes.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            WatchAgentMain.uiAppURL().path,
            "--args",
            "--steal-finder"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
