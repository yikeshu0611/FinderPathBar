import AppKit

/// Menu-bar (status item) entry for NewFinder when running without a Dock icon.
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "NewFinder")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NewFinder"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 NewFinder", action: #selector(showNewFinder), keyEquivalent: "")
        menu.addItem(withTitle: "新建窗口", action: #selector(newWindow), keyEquivalent: "n")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 NewFinder", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func showNewFinder() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        if let front = AppDelegate.shared.keyBrowserForStatusBar() {
            front.window?.makeKeyAndOrderFront(nil)
        } else {
            AppDelegate.shared.openNewWindow(at: desktop)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newWindow() {
        AppDelegate.shared.newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        AppDelegate.shared.showPreferences(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
