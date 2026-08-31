import AppKit
import CoreGraphics
import CoreServices
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showUINotification = Notification.Name("com.zhangjing.NewFinder.showUI")
    static let stealFinderNotification = Notification.Name("com.zhangjing.NewFinder.stealFinder")

    private var windowControllers: [BrowserWindowController] = []
    private var isRedirectingFinder = false
    private var lastFinderRedirectAt: Date?
    private var finderWindowPollTimer: Timer?
    private var pendingRedirectWorkItem: DispatchWorkItem?
    private var didWarnFinderAutomation = false

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep accessory policy so NewFinder stays out of the Dock.
        NSApp.setActivationPolicy(.accessory)

        // Agent-style apps can spawn many instances; keep a single UI process.
        if handOffToExistingUIInstanceIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = buildMainMenu()
        StatusBarController.shared.install()
        registerAsDefaultFolderViewer()
        applyLaunchAtLoginSetting()
        installWatchAgent()
        startFinderRedirectObserver()
        registerExternalShowObservers()

        let stealFinder = CommandLine.arguments.contains("--steal-finder")
        if stealFinder {
            // Relaunched after Dock-Finder click: steal immediately, then ensure a window.
            scheduleFinderRedirect(settle: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.showFrontBrowserOrOpenDesktop()
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // `open` may also call applicationShouldHandleReopen — only create one window.
            showFrontBrowserOrOpenDesktop()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// If another UI instance is already running, ask it to show and exit this process.
    private func handOffToExistingUIInstanceIfNeeded() -> Bool {
        guard let existing = otherUIInstances().first else { return false }
        let center = DistributedNotificationCenter.default()
        let bid = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"
        if CommandLine.arguments.contains("--steal-finder") {
            center.postNotificationName(Self.stealFinderNotification, object: bid, userInfo: nil, deliverImmediately: true)
        } else {
            center.postNotificationName(Self.showUINotification, object: bid, userInfo: nil, deliverImmediately: true)
        }
        existing.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    private func otherUIInstances() -> [NSRunningApplication] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let bid = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != selfPID && !$0.isTerminated }
    }

    private func registerExternalShowObservers() {
        let center = DistributedNotificationCenter.default()
        let bid = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"
        center.addObserver(
            self,
            selector: #selector(handleExternalShowUI(_:)),
            name: Self.showUINotification,
            object: bid
        )
        center.addObserver(
            self,
            selector: #selector(handleExternalStealFinder(_:)),
            name: Self.stealFinderNotification,
            object: bid
        )
    }

    @objc private func handleExternalShowUI(_ notification: Notification) {
        showFrontBrowserOrOpenDesktop()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleExternalStealFinder(_ notification: Notification) {
        scheduleFinderRedirect(settle: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.showFrontBrowserOrOpenDesktop()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showFrontBrowserOrOpenDesktop() {
        if let front = keyBrowser() {
            front.window?.makeKeyAndOrderFront(nil)
        } else {
            openNewWindow(
                at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            )
        }
    }

    /// Keep a background watch process so Dock-Finder still routes to NewFinder after Quit.
    private func installWatchAgent() {
        let label = "com.zhangjing.NewFinder.Watch"
        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistURL = agents.appendingPathComponent("\(label).plist")
        // Separate helper app → different bundle ID, so `open NewFinder` is not blocked.
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NewFinderWatch.app/Contents/MacOS/NewFinderWatch")
            .path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }

        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive"
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return
        }

        // Load or kick the agent (ignore errors if already loaded).
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", plistURL.path]
        unload.standardOutput = FileHandle.nullDevice
        unload.standardError = FileHandle.nullDevice
        try? unload.run()
        unload.waitUntilExit()

        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["load", plistURL.path]
        load.standardOutput = FileHandle.nullDevice
        load.standardError = FileHandle.nullDevice
        try? load.run()
        load.waitUntilExit()
    }

    /// Stay alive with no windows so Finder interception keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Accessory apps sometimes report `flag == false` even with a visible window.
        showFrontBrowserOrOpenDesktop()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openURLs(filenames.map { URL(fileURLWithPath: $0) })
        NSApp.reply(toOpenOrPrint: .success)
    }

    /// Open folders in NewFinder; reveal files by showing their parent and selecting them.
    func openURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let standardized = urls.map { $0.standardizedFileURL }

        var directories: [URL] = []
        var files: [URL] = []
        for url in standardized {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isPackage == true {
                NSWorkspace.shared.open(url)
                continue
            }
            if values?.isDirectory == true {
                directories.append(url)
            } else {
                files.append(url)
            }
        }

        for dir in directories {
            openDirectory(dir)
        }
        if !files.isEmpty {
            reveal(files)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show items inside NewFinder (replaces system Finder reveal).
    func reveal(_ urls: [URL]) {
        guard let first = urls.first?.standardizedFileURL else { return }
        let values = try? first.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true, urls.count == 1 {
            openDirectory(first)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let parent = first.deletingLastPathComponent()
        let select = urls.map(\.standardizedFileURL)

        // Set pending selection BEFORE navigating so async reload still selects the file.
        if let front = keyBrowser() {
            front.selectAfterNavigate(select)
            front.openDirectoryInTab(parent)
        } else {
            let browser = openNewWindow(at: parent)
            browser.selectAfterNavigate(select)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newWindow(_ sender: Any?) {
        let url = keyBrowser()?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        openDirectory(url)
    }

    @objc func showPreferences(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @discardableResult
    func openDirectory(_ url: URL) -> BrowserWindowController {
        if let front = keyBrowser() {
            front.openDirectoryInTab(url)
            front.window?.makeKeyAndOrderFront(nil)
            return front
        }
        return openNewWindow(at: url)
    }

    @discardableResult
    func openNewWindow(at url: URL) -> BrowserWindowController {
        let controller = BrowserWindowController(directory: url)
        register(controller)
        controller.showWindow(nil)
        return controller
    }

    @discardableResult
    func openNewWindow(with tab: BrowserTab, screenPoint: NSPoint) -> BrowserWindowController {
        let controller = BrowserWindowController(tabs: [tab], activeID: tab.id)
        register(controller)
        if let window = controller.window {
            var frame = window.frame
            frame.origin = NSPoint(
                x: screenPoint.x - min(120, frame.width / 4),
                y: screenPoint.y - frame.height + 40
            )
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            }
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    private func register(_ controller: BrowserWindowController) {
        windowControllers.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
        }
    }

    private func keyBrowser() -> BrowserWindowController? {
        if let key = NSApp.keyWindow,
           let match = windowControllers.first(where: { $0.window === key }) {
            return match
        }
        return windowControllers.last
    }

    /// True when at least one browser window is still open (not closed).
    private func hasActiveBrowserWindow() -> Bool {
        !windowControllers.isEmpty
    }

    /// Used by the menu-bar status item.
    func keyBrowserForStatusBar() -> BrowserWindowController? {
        keyBrowser()
    }

    // MARK: - Default folder handler

    func registerAsDefaultFolderViewer() {
        let appURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"

        let types: [UTType] = [.folder, .directory, .volume]
        // Do not claim public.symlink / alias-file — those often point at documents, not folders.

        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { _ in }
            LSSetDefaultRoleHandlerForContentType(
                type.identifier as CFString,
                LSRolesMask.viewer,
                bundleID as CFString
            )
            LSSetDefaultRoleHandlerForContentType(
                type.identifier as CFString,
                LSRolesMask.all,
                bundleID as CFString
            )
        }

        // Force Launch Services to re-scan this build.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsregister)
            process.arguments = ["-f", appURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    func applyLaunchAtLoginSetting() {
        let enabled = AppSettings.shared.launchAtLogin
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // User may need to allow in System Settings → Login Items.
        }
    }

    // MARK: - Finder interception

    private func startFinderRedirectObserver() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleWorkspaceAppNote(note)
        }
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleWorkspaceAppNote(note)
        }
        center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleWorkspaceAppNote(note)
        }
        updateFinderWindowPollTimer()
    }

    private func handleWorkspaceAppNote(_ note: Notification) {
        guard AppSettings.shared.redirectFinderClicks else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.finder" else { return }
        // Tiny settle so selection exists; keep short to avoid visible lag.
        scheduleFinderRedirect(settle: 0.04)
    }

    func updateFinderWindowPollTimer() {
        finderWindowPollTimer?.invalidate()
        finderWindowPollTimer = nil
        guard AppSettings.shared.redirectFinderClicks else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.pollFinderWindowsIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        finderWindowPollTimer = timer
    }

    private func scheduleFinderRedirect(settle: TimeInterval) {
        guard AppSettings.shared.redirectFinderClicks else { return }
        pendingRedirectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.redirectFinderActivationToNewFinder()
        }
        pendingRedirectWorkItem = work
        if settle <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        }
    }

    private func pollFinderWindowsIfNeeded() {
        guard AppSettings.shared.redirectFinderClicks else { return }
        guard !isRedirectingFinder else { return }
        // CGWindowList is much faster than AppleScript for detection.
        guard finderLooksLikeItHasBrowserWindows() else { return }
        scheduleFinderRedirect(settle: 0)
    }

    /// Fast path: detect Finder browser windows without AppleScript.
    private func finderLooksLikeItHasBrowserWindows() -> Bool {
        let finderPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .processIdentifier
        guard let finderPID else { return false }

        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let screenH = NSScreen.main?.frame.height ?? 900
        let screenW = NSScreen.main?.frame.width ?? 1400

        for win in info {
            guard let pid = win[kCGWindowOwnerPID as String] as? pid_t, pid == finderPID else { continue }
            let layer = win[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard let bounds = win[kCGWindowBounds as String] as? [String: Any] else { continue }
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            // Ignore menu-sized chrome; ignore full-screen desktop window.
            if height < 120 || width < 160 { continue }
            if height >= screenH - 40 && width >= screenW - 40 { continue }
            return true
        }
        return false
    }

    private func redirectFinderActivationToNewFinder() {
        guard AppSettings.shared.redirectFinderClicks else { return }
        guard !isRedirectingFinder else { return }
        if let last = lastFinderRedirectAt, Date().timeIntervalSince(last) < 0.18 {
            return
        }

        let frontIsFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        guard frontIsFinder || finderLooksLikeItHasBrowserWindows() else { return }

        isRedirectingFinder = true
        lastFinderRedirectAt = Date()

        // Switch focus first so the Finder flash is as short as possible.
        forceActivateNewFinder()

        let context = probeFinderContext()
        closeFinderWindowsViaAppleScript()
        applyFinderContext(context)

        if context.selectURLs.isEmpty && context.folderURL == nil {
            // Selection may arrive a frame later (Chrome). One quick async retry only.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                let again = self.probeFinderContext()
                if !again.selectURLs.isEmpty || again.folderURL != nil {
                    self.closeFinderWindowsViaAppleScript()
                    self.applyFinderContext(again)
                    self.forceActivateNewFinder()
                } else if self.finderLooksLikeItHasBrowserWindows() || self.finderHasOpenWindows() {
                    self.noteFinderAutomationFailureIfNeeded()
                }
                self.isRedirectingFinder = false
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.isRedirectingFinder = false
            }
        }
    }

    private func applyFinderContext(_ context: FinderContext) {
        if !context.selectURLs.isEmpty {
            reveal(context.selectURLs)
        } else if hasActiveBrowserWindow() {
            // NF already open: steal focus only; do not open Desktop / new tab from Finder dock click.
            keyBrowser()?.window?.makeKeyAndOrderFront(nil)
        } else if let folder = context.folderURL {
            openNewWindow(at: folder)
        } else {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            openNewWindow(at: desktop)
        }
        forceActivateNewFinder()
    }

    private func forceActivateNewFinder() {
        NSApp.activate(ignoringOtherApps: true)
        let bid = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"
        NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .first?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func noteFinderAutomationFailureIfNeeded() {
        guard !didWarnFinderAutomation else { return }
        didWarnFinderAutomation = true
        let alert = NSAlert()
        alert.messageText = "需要允许控制 Finder"
        alert.informativeText = """
        Chrome 等应用的「在文件夹中显示」会打开系统 Finder。NewFinder 需要「自动化」权限才能接管。

        请打开：系统设置 → 隐私与安全性 → 自动化 → NewFinder → 勾选 Finder。
        然后重试 Chrome 里的文件夹按钮。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private struct FinderContext {
        var folderURL: URL?
        var selectURLs: [URL]
    }

    private func runAppleScript(_ source: String) -> (string: String?, error: NSDictionary?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return (nil, ["status": "compile failed"] as NSDictionary)
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            return (result.stringValue, error)
        }
        return (result.stringValue, nil)
    }

    private func probeFinderContext() -> FinderContext {
        let source = """
        tell application "Finder"
          set output to ""
          try
            set sel to the selection
            if (count of sel) > 0 then
              repeat with s in sel
                try
                  set output to output & POSIX path of (s as alias) & linefeed
                end try
              end repeat
              if output is not "" then return "SEL:" & output
            end if
          end try
          try
            if (count of Finder windows) > 0 then
              set t to target of front Finder window
              return "DIR:" & POSIX path of (t as alias)
            end if
          end try
          return ""
        end tell
        """
        let (raw, _) = runAppleScript(source)
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return FinderContext(folderURL: nil, selectURLs: [])
        }

        if text.hasPrefix("SEL:") {
            let body = String(text.dropFirst(4))
            let paths = body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return FinderContext(folderURL: nil, selectURLs: paths.map { URL(fileURLWithPath: $0) })
        }
        if text.hasPrefix("DIR:") {
            let path = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return FinderContext(folderURL: nil, selectURLs: []) }
            return FinderContext(folderURL: URL(fileURLWithPath: path), selectURLs: [])
        }
        return FinderContext(folderURL: nil, selectURLs: [])
    }

    private func finderHasOpenWindows() -> Bool {
        let (value, error) = runAppleScript("""
        tell application "Finder"
          try
            return (count of Finder windows) as string
          end try
          return "0"
        end tell
        """)
        if error != nil { return false }
        return Int(value ?? "0") ?? 0 > 0
    }

    private func closeFinderWindowsViaAppleScript() {
        _ = runAppleScript("""
        tell application "Finder"
          try
            close every window
          end try
        end tell
        """)
    }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 NewFinder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 NewFinder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 NewFinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "新建窗口", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.items.last?.toolTip = "在当前窗口新建标签页（无窗口时才新建窗口）"
        fileMenu.addItem(withTitle: "新建标签页", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "新建文件夹", action: #selector(BrowserWindowController.newFolder(_:)), keyEquivalent: "N")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "关闭", action: #selector(BrowserWindowController.closeActiveTabOrWindow(_:)), keyEquivalent: "w")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "剪切", action: #selector(BrowserWindowController.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(BrowserWindowController.copy(_:)), keyEquivalent: "c")
        let copyPathItem = editMenu.addItem(withTitle: "复制路径", action: #selector(BrowserWindowController.copyPath(_:)), keyEquivalent: "C")
        copyPathItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "粘贴", action: #selector(BrowserWindowController.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(BrowserWindowController.selectAllItems(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "重命名", action: #selector(BrowserWindowController.rename(_:)), keyEquivalent: String(UnicodeScalar(NSF2FunctionKey)!))
        editMenu.items.last?.keyEquivalentModifierMask = []

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "显示路径栏", action: #selector(BrowserWindowController.togglePathBar(_:)), keyEquivalent: "p")
        viewMenu.addItem(withTitle: "显示隐藏文件", action: #selector(BrowserWindowController.toggleHiddenFiles(_:)), keyEquivalent: ".")

        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: "前往")
        goMenuItem.submenu = goMenu
        goMenu.addItem(withTitle: "后退", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "前进", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        let upItem = goMenu.addItem(withTitle: "上层文件夹", action: #selector(BrowserWindowController.goEnclosingFolder(_:)), keyEquivalent: "↑")
        upItem.keyEquivalentModifierMask = [.command]
        goMenu.addItem(NSMenuItem.separator())
        goMenu.addItem(withTitle: "前往文件夹…", action: #selector(BrowserWindowController.focusPathBar(_:)), keyEquivalent: "l")
        goMenu.addItem(withTitle: "电脑", action: #selector(BrowserWindowController.goComputer(_:)), keyEquivalent: "C")
        goMenu.addItem(withTitle: "个人", action: #selector(BrowserWindowController.goHome(_:)), keyEquivalent: "H")
        goMenu.addItem(withTitle: "桌面", action: #selector(BrowserWindowController.goDesktop(_:)), keyEquivalent: "D")
        goMenu.addItem(withTitle: "文稿", action: #selector(BrowserWindowController.goDocuments(_:)), keyEquivalent: "O")
        goMenu.addItem(withTitle: "下载", action: #selector(BrowserWindowController.goDownloads(_:)), keyEquivalent: "L")
        goMenu.addItem(NSMenuItem.separator())
        let bookmarksItem = goMenu.addItem(withTitle: "收藏", action: nil, keyEquivalent: "")
        bookmarksItem.submenu = NSMenu(title: "收藏")
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: bookmarksItem.submenu,
            queue: .main
        ) { _ in
            guard let menu = bookmarksItem.submenu else { return }
            menu.removeAllItems()
            let bookmarks = AppSettings.shared.bookmarks
            if bookmarks.isEmpty {
                let empty = menu.addItem(withTitle: "暂无收藏", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                return
            }
            for bookmark in bookmarks {
                let item = menu.addItem(
                    withTitle: bookmark.name,
                    action: #selector(BrowserWindowController.openBookmarkMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = bookmark.path
                item.toolTip = bookmark.path
            }
        }

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
