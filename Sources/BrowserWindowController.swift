import AppKit

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settings = AppSettings.shared
    private var tabs: [BrowserTab] = []
    private var activeTabID: UUID!

    private var history: NavigationHistory {
        activeTab.history
    }

    private var activeTab: BrowserTab {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    private var chromeHeader: ChromeHeaderView!
    private var contentController: ContentViewController!
    private var pathBarContainer: NSView!
    private var pathField: NSTextField!
    private var breadcrumbStack: NSStackView!
    private var historyMenuButton: NSButton!
    private var copyPathButton: NSButton!
    private var copyPathFlashToken = 0
    private var pathBookmarkButton: NSButton!
    private var pathBarVisible = true
    private var statusLabel: NSTextField!
    private var autocompletePanel: NSPanel?
    private var autocompleteList: NSTableView?
    private var autocompleteCandidates: [String] = []
    private var isEditingPath = false
    private var pathEditClickMonitor: Any?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var pendingSelectURLs: [URL] = []
    private var pendingRenameURL: URL?
    private var suppressDirectoryWatchUntil: Date?
    private var contentLoadGeneration = 0
    private var pendingReloadWorkItem: DispatchWorkItem?
    private var searchField: NSSearchField!
    private var pathBarTopConstraint: NSLayoutConstraint!
    private var bookmarkEditorPanel: NSPanel?
    private weak var bookmarkFolderField: NSTextField?
    private weak var bookmarkFolderPicker: NSPopUpButton?
    private weak var bookmarkNameField: NSTextField?
    private weak var bookmarkPathField: NSTextField?
    private var editingBookmarkID: UUID?
    private var editingBookmarkFolderName: String?

    private(set) var currentDirectory: URL {
        get { activeTab.directory }
        set { activeTab.directory = newValue.standardizedFileURL }
    }

    convenience init(directory: URL) {
        let initial = directory.standardizedFileURL
        let tab = BrowserTab(directory: initial)
        self.init(tabs: [tab], activeID: tab.id)
    }

    init(tabs: [BrowserTab], activeID: UUID) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 420)
        window.center()
        super.init(window: window)
        window.delegate = self

        self.tabs = tabs
        self.activeTabID = activeID

        configureUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentTrash),
            name: .contentRequestTrash,
            object: nil
        )
        navigate(to: activeTab.directory, recordHistory: false)
        refreshTabBar()
    }

    @objc private func handleContentTrash(_ note: Notification) {
        guard (note.object as? ContentViewController) === contentController else { return }
        moveToTrash(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI() {
        guard let window else { return }

        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        window.toolbar = nil

        chromeHeader = ChromeHeaderView()
        chromeHeader.translatesAutoresizingMaskIntoConstraints = false
        chromeHeader.bind(target: self)
        chromeHeader.onSelectTab = { [weak self] id in self?.selectTab(id) }
        chromeHeader.onCloseTab = { [weak self] id in self?.closeTab(id) }
        chromeHeader.onNewTab = { [weak self] in self?.newTab(nil) }
        chromeHeader.onNewTabRelative = { [weak self] id, side in
            self?.newTab(relativeTo: id, side: side == .left ? .left : .right)
        }
        chromeHeader.onCloseTabsRelative = { [weak self] id, scope in
            switch scope {
            case .thisTab: self?.closeTabs(relativeTo: id, scope: .this)
            case .left: self?.closeTabs(relativeTo: id, scope: .left)
            case .right: self?.closeTabs(relativeTo: id, scope: .right)
            case .others: self?.closeTabs(relativeTo: id, scope: .others)
            }
        }
        chromeHeader.onDetachTab = { [weak self] id, screenPoint in
            self?.detachTabToNewWindow(id, screenPoint: screenPoint)
        }
        searchField = chromeHeader.searchFieldView

        pathBarContainer = ClickablePathBarView()
        pathBarContainer.translatesAutoresizingMaskIntoConstraints = false
        pathBarContainer.wantsLayer = true
        pathBarContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        (pathBarContainer as? ClickablePathBarView)?.onBackgroundClick = { [weak self] in
            guard let self else { return }
            if self.isEditingPath {
                self.endPathEditing(commit: false)
            } else {
                self.beginPathEditing()
            }
        }

        historyMenuButton = NSButton()
        historyMenuButton.bezelStyle = .inline
        historyMenuButton.isBordered = false
        historyMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "访问历史")
        historyMenuButton.image?.isTemplate = true
        historyMenuButton.contentTintColor = .secondaryLabelColor
        historyMenuButton.toolTip = "访问历史"
        historyMenuButton.target = self
        historyMenuButton.action = #selector(showHistoryMenu(_:))
        historyMenuButton.translatesAutoresizingMaskIntoConstraints = false
        historyMenuButton.focusRingType = .none

        copyPathButton = NSButton()
        copyPathButton.bezelStyle = .inline
        copyPathButton.isBordered = false
        copyPathButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制路径")
        copyPathButton.image?.isTemplate = true
        copyPathButton.contentTintColor = .labelColor
        copyPathButton.toolTip = "复制路径 (⌘⇧C)"
        copyPathButton.target = self
        copyPathButton.action = #selector(copyPath(_:))
        copyPathButton.translatesAutoresizingMaskIntoConstraints = false
        copyPathButton.focusRingType = .none

        pathBookmarkButton = NSButton()
        pathBookmarkButton.bezelStyle = .inline
        pathBookmarkButton.isBordered = false
        pathBookmarkButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "收藏当前地址")
        pathBookmarkButton.image?.isTemplate = true
        pathBookmarkButton.contentTintColor = .labelColor
        pathBookmarkButton.toolTip = "收藏当前地址"
        pathBookmarkButton.target = self
        pathBookmarkButton.action = #selector(showBookmarkEditor(_:))
        pathBookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        pathBookmarkButton.focusRingType = .none

        breadcrumbStack = PassThroughStackView()
        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.spacing = 2
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbStack.setHuggingPriority(.defaultLow, for: .horizontal)

        pathField = NSTextField()
        pathField.placeholderString = "输入路径后回车前往，Esc 取消"
        pathField.isBordered = true
        pathField.isBezeled = true
        pathField.bezelStyle = .roundedBezel
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.delegate = self
        pathField.isHidden = true
        pathField.translatesAutoresizingMaskIntoConstraints = false

        pathBarContainer.addSubview(copyPathButton)
        pathBarContainer.addSubview(historyMenuButton)
        pathBarContainer.addSubview(breadcrumbStack)
        pathBarContainer.addSubview(pathField)
        pathBarContainer.addSubview(pathBookmarkButton)

        contentController = ContentViewController()
        contentController.onOpen = { [weak self] item in
            self?.openItem(item)
        }
        contentController.onSelectionChange = { [weak self] items in
            self?.updateStatus(selection: items)
        }
        contentController.onRenameRequest = { [weak self] item in
            self?.contentController.beginInlineRename(item)
        }
        contentController.onCommitRename = { [weak self] item, newName in
            self?.commitRename(item, to: newName)
        }
        contentController.view.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusBar.addSubview(statusLabel)

        root.addSubview(chromeHeader)
        root.addSubview(pathBarContainer)
        root.addSubview(contentController.view)
        root.addSubview(statusBar)

        pathBarTopConstraint = pathBarContainer.topAnchor.constraint(equalTo: chromeHeader.bottomAnchor)

        NSLayoutConstraint.activate([
            chromeHeader.topAnchor.constraint(equalTo: root.topAnchor),
            chromeHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chromeHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chromeHeader.heightAnchor.constraint(equalToConstant: 62),

            pathBarTopConstraint,
            pathBarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBarContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBarContainer.heightAnchor.constraint(equalToConstant: 28),

            copyPathButton.leadingAnchor.constraint(equalTo: pathBarContainer.leadingAnchor, constant: 6),
            copyPathButton.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            copyPathButton.widthAnchor.constraint(equalToConstant: 22),
            copyPathButton.heightAnchor.constraint(equalToConstant: 22),

            historyMenuButton.leadingAnchor.constraint(equalTo: copyPathButton.trailingAnchor, constant: 2),
            historyMenuButton.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            historyMenuButton.widthAnchor.constraint(equalToConstant: 18),
            historyMenuButton.heightAnchor.constraint(equalToConstant: 18),

            breadcrumbStack.leadingAnchor.constraint(equalTo: historyMenuButton.trailingAnchor, constant: 4),
            breadcrumbStack.trailingAnchor.constraint(lessThanOrEqualTo: pathBookmarkButton.leadingAnchor, constant: -8),
            breadcrumbStack.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),

            pathField.leadingAnchor.constraint(equalTo: historyMenuButton.trailingAnchor, constant: 4),
            pathField.trailingAnchor.constraint(equalTo: pathBookmarkButton.leadingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            pathField.heightAnchor.constraint(equalToConstant: 22),

            pathBookmarkButton.trailingAnchor.constraint(equalTo: pathBarContainer.trailingAnchor, constant: -8),
            pathBookmarkButton.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            pathBookmarkButton.widthAnchor.constraint(equalToConstant: 22),
            pathBookmarkButton.heightAnchor.constraint(equalToConstant: 22),

            contentController.view.topAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),
            contentController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentController.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])

        updatePathChrome()
    }

    // MARK: - Tabs

    private func refreshTabBar() {
        chromeHeader.setTabs(tabs, activeID: activeTabID)
    }

    @objc func newTab(_ sender: Any?) {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let tab = BrowserTab(directory: desktop.standardizedFileURL)
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
    }

    /// Open a directory as a new tab (or switch to an existing tab with the same path).
    func openDirectoryInTab(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            NSSound.beep()
            return
        }
        let standardized = url.standardizedFileURL
        if let existing = tabs.first(where: { $0.directory.standardizedFileURL == standardized }) {
            if existing.id == activeTabID {
                window?.makeKeyAndOrderFront(nil)
                searchField.stringValue = ""
                // Revealing a file (pending select) or an empty/stale list must reload.
                if !pendingSelectURLs.isEmpty || contentController.items.isEmpty {
                    reloadContents()
                } else {
                    applyPendingSelection(clearIfSelected: true)
                }
                return
            }
            selectTab(existing.id)
            return
        }
        let tab = BrowserTab(directory: standardized)
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
    }

    private enum TabSide { case left, right }
    private enum TabCloseScope { case this, left, right, others }

    private func newTab(relativeTo id: UUID, side: TabSide) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            let tab = BrowserTab(directory: currentDirectory)
            tabs.append(tab)
            selectTab(tab.id)
            return
        }
        let directory = tabs[index].directory
        let tab = BrowserTab(directory: directory)
        let insertAt = side == .left ? index : index + 1
        tabs.insert(tab, at: insertAt)
        selectTab(tab.id)
    }

    private func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        refreshTabBar()
        navigate(to: tab.directory, recordHistory: false)
    }

    private func closeTab(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else {
            window?.performClose(nil)
            return
        }
        let wasActive = id == activeTabID
        tabs.remove(at: index)
        if wasActive {
            let next = tabs[min(index, tabs.count - 1)]
            activeTabID = next.id
            navigate(to: next.directory, recordHistory: false)
        }
        refreshTabBar()
    }

    private func detachTabToNewWindow(_ id: UUID, screenPoint: NSPoint) {
        guard let tab = extractTab(id) else { return }
        let shouldCloseSource = tabs.isEmpty
        AppDelegate.shared.openNewWindow(with: tab, screenPoint: screenPoint)
        if shouldCloseSource {
            window?.close()
        }
    }

    /// Remove a tab from this window and return it.
    private func extractTab(_ id: UUID) -> BrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if tabs.isEmpty {
            refreshTabBar()
            return tab
        }
        let wasActive = id == activeTabID
        if wasActive {
            let next = tabs[min(index, tabs.count - 1)]
            activeTabID = next.id
            navigate(to: next.directory, recordHistory: false)
        }
        refreshTabBar()
        return tab
    }

    private func closeTabs(relativeTo id: UUID, scope: TabCloseScope) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch scope {
        case .this:
            closeTab(id)
        case .left:
            guard index > 0 else { return }
            let keep = Array(tabs[index...])
            let closingActive = tabs[..<index].contains(where: { $0.id == activeTabID })
            tabs = keep
            if closingActive { selectTab(id) } else { refreshTabBar() }
        case .right:
            guard index < tabs.count - 1 else { return }
            let keep = Array(tabs[...index])
            let closingActive = tabs[(index + 1)...].contains(where: { $0.id == activeTabID })
            tabs = keep
            if closingActive { selectTab(id) } else { refreshTabBar() }
        case .others:
            guard tabs.count > 1 else { return }
            let keep = tabs[index]
            tabs = [keep]
            selectTab(keep.id)
        }
    }

    @objc func closeActiveTabOrWindow(_ sender: Any?) {
        if tabs.count > 1 {
            closeTab(activeTabID)
        } else {
            window?.performClose(nil)
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            NSSound.beep()
            return
        }
        let standardized = url.standardizedFileURL
        currentDirectory = standardized
        if recordHistory {
            history.navigate(to: standardized)
        }
        window?.title = standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
        updatePathChrome()
        searchField.stringValue = ""
        hideAutocomplete()
        // Always reload the file list so address/tab and table contents stay in sync.
        watchDirectory(standardized)
        reloadContents()
        refreshTabBar()
    }

    func selectAfterNavigate(_ urls: [URL]) {
        let targets = urls.map(\.standardizedFileURL)
        guard !targets.isEmpty else { return }
        pendingSelectURLs = targets
        // Keep pending until reload finishes so setItems cannot leave an empty unselected list.
        applyPendingSelection(clearIfSelected: false)
    }

    private func applyPendingSelection(clearIfSelected: Bool) {
        guard !pendingSelectURLs.isEmpty else { return }
        contentController.select(urls: pendingSelectURLs)
        if clearIfSelected, !contentController.selectedItems.isEmpty {
            pendingSelectURLs = []
        }
    }

    private func reloadContents() {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil

        contentLoadGeneration += 1
        let generation = contentLoadGeneration
        let directory = currentDirectory
        let showHidden = settings.showHiddenFiles
        statusLabel.stringValue = "正在加载…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = FileOperations.listDirectory(directory, showHidden: showHidden)
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.contentLoadGeneration else { return }
                guard self.currentDirectory.standardizedFileURL == directory.standardizedFileURL else { return }
                self.contentController.setItems(items, alreadySortedByName: true)
                // Read pending HERE (not before async) so reveal-after-navigate still works.
                if !self.pendingSelectURLs.isEmpty {
                    self.contentController.select(urls: self.pendingSelectURLs)
                    self.pendingSelectURLs = []
                }
                self.updateStatus(selection: self.contentController.selectedItems)
                if let renameURL = self.pendingRenameURL {
                    self.pendingRenameURL = nil
                    if let item = self.contentController.items.first(where: {
                        $0.url.standardizedFileURL == renameURL.standardizedFileURL
                    }) {
                        // Next runloop so the table cell exists for inline editing.
                        DispatchQueue.main.async {
                            self.contentController.beginInlineRename(item)
                        }
                    }
                }
            }
        }
    }

    private func scheduleReloadContents() {
        if let until = suppressDirectoryWatchUntil, Date() < until {
            return
        }
        pendingReloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadContents()
        }
        pendingReloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func updatePathChrome() {
        pathField.stringValue = currentDirectory.path
        breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let components = currentDirectory.pathComponents
        var built = ""
        for (index, component) in components.enumerated() {
            if index == 0 {
                built = "/"
            } else if built == "/" {
                built += component
            } else {
                built += "/" + component
            }

            let title = index == 0 ? "Macintosh HD" : component
            let button = BreadcrumbButton(title: title, target: self, action: #selector(breadcrumbClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(built)
            breadcrumbStack.addArrangedSubview(button)

            if index < components.count - 1 {
                let chevron = BreadcrumbChevronButton()
                chevron.directoryPath = built
                chevron.onClick = { [weak self, weak chevron] in
                    guard let self, let chevron else { return }
                    DispatchQueue.main.async {
                        self.showBreadcrumbDirectoryMenu(at: built, from: chevron)
                    }
                }
                breadcrumbStack.addArrangedSubview(chevron)
            }
        }

        breadcrumbStack.isHidden = isEditingPath
        pathField.isHidden = !isEditingPath
        refreshBookmarkUI()
    }

    private func refreshBookmarkUI() {
        let path = currentDirectory.standardizedFileURL.path
        let isBookmarked = settings.bookmarks.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }
        updatePathBookmarkButton(isBookmarked: isBookmarked)
        rebuildBookmarkFolderButtons()
    }

    private func updatePathBookmarkButton(isBookmarked: Bool) {
        let symbol = isBookmarked ? "star.fill" : "star"
        let tip = isBookmarked ? "编辑收藏" : "收藏当前地址"
        pathBookmarkButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        pathBookmarkButton.image?.isTemplate = true
        pathBookmarkButton.contentTintColor = isBookmarked ? .systemYellow : .secondaryLabelColor
        pathBookmarkButton.toolTip = tip
    }

    private func orderedBookmarkFolders() -> [String] {
        let allFolders = Array(Set(settings.bookmarks.map(\.folder)))
        let available = Set(allFolders)
        let stored = settings.bookmarkFolderOrder.filter { available.contains($0) }
        let newer = allFolders
            .filter { !stored.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return stored + newer
    }

    private func rebuildBookmarkFolderButtons() {
        let stack = chromeHeader.bookmarkFoldersContainer
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for folder in orderedBookmarkFolders() {
            let button = BookmarkFolderButton(title: folder, target: nil, action: nil)
            button.folderName = folder
            button.attributedTitle = NSAttributedString(
                string: folder,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor(calibratedWhite: 0.32, alpha: 1)
                ]
            )
            button.toolTip = "打开收藏夹「\(folder)」（拖动排序，右键重命名）"
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                DispatchQueue.main.async {
                    self.showBookmarkFolderMenu(folder, from: button)
                }
            }
            button.onRightClick = { [weak self] in
                self?.showBookmarkFolderEditor(folder)
            }
            button.onOrderChanged = { [weak self] in
                self?.persistBookmarkFolderOrderFromStack()
            }
            stack.addArrangedSubview(button)
        }
    }

    private func persistBookmarkFolderOrderFromStack() {
        let stack = chromeHeader.bookmarkFoldersContainer
        let order = stack.arrangedSubviews.compactMap { ($0 as? BookmarkFolderButton)?.folderName }
        guard !order.isEmpty else { return }
        settings.bookmarkFolderOrder = order
    }

    private func showBookmarkFolderMenu(_ folder: String, from sourceButton: NSButton) {
        let folderBookmarks = settings.bookmarks
            .filter { $0.folder == folder }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !folderBookmarks.isEmpty else { return }

        let menu = NSMenu(title: folder)
        let itemFont = NSFont.systemFont(ofSize: 13)
        let rowWidth = max(
            72,
            ceil((folderBookmarks.map { ($0.name as NSString).size(withAttributes: [.font: itemFont]).width }.max() ?? 0) + 24)
        )
        for bookmark in folderBookmarks {
            let item = NSMenuItem(title: bookmark.name, action: nil, keyEquivalent: "")
            let row = BookmarkMenuRowView(title: bookmark.name, path: bookmark.path, font: itemFont, width: rowWidth)
            row.onOpen = { [weak self, weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.navigate(to: URL(fileURLWithPath: bookmark.path))
                }
            }
            row.onEdit = { [weak self, weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.async {
                    self?.presentBookmarkEditor(for: bookmark)
                }
            }
            item.view = row
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sourceButton.bounds.height + 4), in: sourceButton)
    }

    @objc private func breadcrumbClicked(_ sender: Any?) {
        let button = (sender as? BreadcrumbButton) ?? (sender as? NSButton)
        if NSApp.currentEvent?.clickCount ?? 0 >= 2 {
            beginPathEditing()
            return
        }
        guard let path = button?.identifier?.rawValue else { return }
        navigate(to: URL(fileURLWithPath: path))
    }

    private func showBreadcrumbDirectoryMenu(at directoryPath: String, from source: NSView) {
        let dirURL = URL(fileURLWithPath: directoryPath)
        let items = FileOperations.listDirectory(dirURL, showHidden: false)
        let menu = NSMenu()
        menu.autoenablesItems = false

        if items.isEmpty {
            let empty = NSMenuItem(title: "空文件夹", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in items {
                let item = NSMenuItem(
                    title: entry.name,
                    action: #selector(breadcrumbMenuItemClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.url
                item.image = NSWorkspace.shared.icon(forFile: entry.url.path)
                item.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(item)
            }
        }

        // Anchor at the bottom of the path bar so the menu sits below it (AppKit y=0 is bottom).
        let x = source.convert(NSPoint(x: 0, y: 0), to: pathBarContainer).x
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: 0), in: pathBarContainer)
    }

    @objc private func breadcrumbMenuItemClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent())
            selectAfterNavigate([url])
        }
    }

    @objc private func showHistoryMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let visits = history.recentVisits
        if visits.isEmpty {
            let empty = NSMenuItem(title: "暂无历史记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "zh_CN")
            timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

            // Measure widest path + time so columns align.
            let pathFont = NSFont.systemFont(ofSize: 13)
            let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            var maxPathWidth: CGFloat = 120
            var maxTimeWidth: CGFloat = 120
            for visit in visits {
                let path = visit.url.path as NSString
                let time = timeFormatter.string(from: visit.visitedAt) as NSString
                maxPathWidth = max(maxPathWidth, path.size(withAttributes: [.font: pathFont]).width)
                maxTimeWidth = max(maxTimeWidth, time.size(withAttributes: [.font: timeFont]).width)
            }
            maxPathWidth = min(maxPathWidth, 480)
            let rowWidth = 28 + maxPathWidth + 24 + maxTimeWidth + 16

            for visit in visits {
                let path = visit.url.path
                let time = timeFormatter.string(from: visit.visitedAt)
                let item = NSMenuItem(title: "", action: #selector(historyMenuItemClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = visit.url
                let isCurrent = visit.url.standardizedFileURL == currentDirectory.standardizedFileURL
                let view = HistoryMenuItemView(
                    path: path,
                    time: time,
                    icon: NSWorkspace.shared.icon(forFile: path),
                    isCurrent: isCurrent,
                    pathWidth: maxPathWidth,
                    timeWidth: maxTimeWidth,
                    rowWidth: rowWidth
                )
                item.view = view
                menu.addItem(item)
            }
        }

        let point = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func historyMenuItemClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigate(to: url)
    }

    private func openItem(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func updateStatus(selection: [FileItem]) {
        let items = contentController.items
        let total = items.count
        let totalSize = formattedTotalSize(of: items)
        let selectedCount = selection.count
        let selectedSize = formattedTotalSize(of: selection)
        statusLabel.stringValue = "\(total) 个项目，\(totalSize)，已选中 \(selectedCount) 个，\(selectedSize)"
    }

    private func formattedTotalSize(of items: [FileItem]) -> String {
        let bytes = items.compactMap(\.fileSize).reduce(Int64(0), +)
        return FileOperations.formatFileSize(bytes)
    }

    // MARK: - Directory watching

    private func watchDirectory(_ url: URL) {
        stopWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReloadContents()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        directoryWatcher = source
        source.resume()
    }

    private func stopWatching() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        watchedFD = -1
    }

    // MARK: - Actions

    @objc func goBack(_ sender: Any?) {
        if let url = history.goBack() {
            navigate(to: url, recordHistory: false)
        }
    }

    @objc func goForward(_ sender: Any?) {
        if let url = history.goForward() {
            navigate(to: url, recordHistory: false)
        }
    }

    @objc func goEnclosingFolder(_ sender: Any?) {
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent.path != currentDirectory.path else { return }
        let left = currentDirectory
        pendingSelectURLs = [left]
        navigate(to: parent)
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func goDesktop(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
    }

    @objc func goDocuments(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
    }

    @objc func goDownloads(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
    }

    @objc func goComputer(_ sender: Any?) {
        navigate(to: URL(fileURLWithPath: "/"))
    }

    @objc func focusPathBar(_ sender: Any?) {
        beginPathEditing()
    }

    @objc func togglePathBar(_ sender: Any?) {
        pathBarVisible.toggle()
        pathBarContainer.isHidden = !pathBarVisible
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        settings.showHiddenFiles.toggle()
        chromeHeader.syncShowHiddenFilesButton(settings.showHiddenFiles)
        reloadContents()
    }

    @objc func newFolder(_ sender: Any?) {
        createNewItem(extensionName: nil, openAfterCreate: false)
    }

    @objc func newItemMenuClicked(_ sender: NSMenuItem) {
        let types = settings.newItemTypes
        guard sender.tag >= 0, sender.tag < types.count else { return }
        let type = types[sender.tag]
        let ext: String? = type.lowercased() == "dir" ? nil : type
        let openAfterCreate = NSEvent.modifierFlags.contains(.option)
        createNewItem(extensionName: ext, openAfterCreate: openAfterCreate)
    }

    private func createNewItem(extensionName: String?, openAfterCreate: Bool) {
        do {
            let url = try FileOperations.createNewItem(in: currentDirectory, extensionName: extensionName)
            pendingSelectURLs = [url]
            // Creating a file triggers directory watch; suppress so reload doesn't kill rename.
            suppressDirectoryWatchUntil = Date().addingTimeInterval(1.2)
            pendingReloadWorkItem?.cancel()
            pendingReloadWorkItem = nil
            if openAfterCreate {
                pendingRenameURL = nil
                reloadContents()
                if extensionName == nil {
                    navigate(to: url)
                } else {
                    NSWorkspace.shared.open(url)
                }
            } else {
                pendingRenameURL = url.standardizedFileURL
                reloadContents()
            }
        } catch {
            showError(error)
        }
    }

    @objc func rename(_ sender: Any?) {
        guard let item = contentController.selectedItems.first else {
            NSSound.beep()
            return
        }
        contentController.beginInlineRename(item)
    }

    private func commitRename(_ item: FileItem, to newName: String) {
        do {
            let dest = try FileOperations.rename(item.url, to: newName)
            reloadContents()
            contentController.select(urls: [dest])
        } catch {
            showError(error)
            reloadContents()
            contentController.select(urls: [item.url])
        }
    }

    @objc func copy(_ sender: Any?) {
        let urls = contentController.selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileOperations.copyURLs(urls)
    }

    @objc func cut(_ sender: Any?) {
        let urls = contentController.selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileOperations.cutURLs(urls)
    }

    @objc func paste(_ sender: Any?) {
        do {
            let urls = try FileOperations.paste(into: currentDirectory)
            reloadContents()
            contentController.select(urls: urls)
        } catch {
            NSSound.beep()
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = contentController.selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        do {
            try FileOperations.moveToTrash(urls)
            reloadContents()
        } catch {
            showError(error)
        }
    }

    @objc func selectAllItems(_ sender: Any?) {
        contentController.selectAll()
    }

    @objc func copyPath(_ sender: Any?) {
        let urls = contentController.selectedItems.map(\.url)
        let text: String
        if urls.isEmpty {
            text = currentDirectory.path
        } else {
            text = urls.map(\.path).joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopyPathSuccess()
    }

    private func flashCopyPathSuccess() {
        copyPathFlashToken += 1
        let token = copyPathFlashToken
        copyPathButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        copyPathButton.image?.isTemplate = true
        copyPathButton.contentTintColor = .systemGreen
        copyPathButton.toolTip = "已复制"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.copyPathFlashToken == token else { return }
            self.copyPathButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制路径")
            self.copyPathButton.image?.isTemplate = true
            self.copyPathButton.contentTintColor = .labelColor
            self.copyPathButton.toolTip = "复制路径"
        }
    }

    @objc func goClipboardPath(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            NSSound.beep()
            return
        }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
            if isDir.boolValue {
                navigate(to: URL(fileURLWithPath: expanded))
            } else {
                let file = URL(fileURLWithPath: expanded)
                pendingSelectURLs = [file]
                navigate(to: file.deletingLastPathComponent())
            }
        } else {
            NSSound.beep()
        }
    }

    @objc func showBookmarkEditor(_ sender: Any?) {
        let path = currentDirectory.standardizedFileURL.path
        let existing = settings.bookmarks.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }
        presentBookmarkEditor(for: existing)
    }

    private func presentBookmarkEditor(for existingBookmark: Bookmark?) {
        let path = existingBookmark?.path ?? currentDirectory.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            statusLabel.stringValue = "没有可收藏的文件夹"
            return
        }

        let existing = existingBookmark ?? settings.bookmarks.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }
        let resumeID = existing?.id
        cancelBookmarkEditor()
        editingBookmarkID = resumeID

        let editor = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        editor.title = "编辑收藏"
        editor.isReleasedWhenClosed = false
        editor.isFloatingPanel = true
        editor.level = .floating

        let content = NSView()
        let defaultFolder = existing?.folder ?? "收藏夹"
        let folderField = NSTextField(string: defaultFolder)
        let folderPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        folderPicker.addItem(withTitle: "选择已有文件夹")
        let existingFolders = Array(Set(settings.bookmarks.map(\.folder))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        for folder in existingFolders {
            folderPicker.addItem(withTitle: folder)
        }
        folderPicker.selectItem(at: 0)
        folderPicker.isEnabled = !existingFolders.isEmpty
        folderPicker.target = self
        folderPicker.action = #selector(bookmarkFolderPickerChanged(_:))

        let defaultName: String = {
            if let existing { return existing.name }
            if path == "/" { return "Macintosh HD" }
            let n = URL(fileURLWithPath: path).lastPathComponent
            return n.isEmpty ? path : n
        }()
        let nameField = NSTextField(string: defaultName)
        let pathField = NSTextField(string: existing?.path ?? path)
        [folderField, folderPicker, nameField, pathField].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let folderLabel = NSTextField(labelWithString: "放置的文件夹名称")
        let nameLabel = NSTextField(labelWithString: "收藏的地址名字")
        let pathLabel = NSTextField(labelWithString: "收藏的地址")
        [folderLabel, nameLabel, pathLabel].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelBookmarkEditor))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveBookmarkEditor))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor

        let removeButton: NSButton? = existing == nil
            ? nil
            : NSButton(title: "取消收藏", target: self, action: #selector(removeBookmarkFromEditor))
        removeButton?.translatesAutoresizingMaskIntoConstraints = false
        removeButton?.contentTintColor = .systemRed

        content.addSubview(folderLabel)
        content.addSubview(folderField)
        content.addSubview(folderPicker)
        content.addSubview(nameLabel)
        content.addSubview(nameField)
        content.addSubview(pathLabel)
        content.addSubview(pathField)
        content.addSubview(cancelButton)
        content.addSubview(saveButton)
        if let removeButton {
            content.addSubview(removeButton)
        }
        editor.contentView = content

        NSLayoutConstraint.activate([
            folderLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            folderLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            folderLabel.widthAnchor.constraint(equalToConstant: 112),
            folderField.leadingAnchor.constraint(equalTo: folderLabel.trailingAnchor, constant: 12),
            folderField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            folderField.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),

            folderPicker.leadingAnchor.constraint(equalTo: folderField.leadingAnchor),
            folderPicker.topAnchor.constraint(equalTo: folderField.bottomAnchor, constant: 8),
            folderPicker.widthAnchor.constraint(equalToConstant: 180),

            nameLabel.leadingAnchor.constraint(equalTo: folderLabel.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: folderPicker.bottomAnchor, constant: 16),
            nameLabel.widthAnchor.constraint(equalTo: folderLabel.widthAnchor),
            nameField.leadingAnchor.constraint(equalTo: folderField.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: folderField.trailingAnchor),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: folderLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 18),
            pathLabel.widthAnchor.constraint(equalTo: folderLabel.widthAnchor),
            pathField.leadingAnchor.constraint(equalTo: folderField.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: folderField.trailingAnchor),
            pathField.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
        ])
        if let removeButton {
            NSLayoutConstraint.activate([
                removeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                removeButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
            ])
        }

        bookmarkEditorPanel = editor
        bookmarkFolderField = folderField
        bookmarkFolderPicker = folderPicker
        bookmarkNameField = nameField
        bookmarkPathField = pathField
        if let host = window {
            let frame = editor.frame
            editor.setFrameOrigin(NSPoint(
                x: host.frame.midX - frame.width / 2,
                y: host.frame.midY - frame.height / 2
            ))
        } else {
            editor.center()
        }
        editor.makeKeyAndOrderFront(nil)
        editor.makeFirstResponder(nameField)
    }

    @objc private func cancelBookmarkEditor() {
        bookmarkEditorPanel?.orderOut(nil)
        bookmarkEditorPanel = nil
        editingBookmarkID = nil
    }

    @objc private func bookmarkFolderPickerChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0 else { return }
        bookmarkFolderField?.stringValue = sender.titleOfSelectedItem ?? ""
    }

    @objc private func saveBookmarkEditor() {
        let folder = bookmarkFolderField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = bookmarkNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawPath = bookmarkPathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = (rawPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !folder.isEmpty, !name.isEmpty, !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            statusLabel.stringValue = "请填写有效的文件夹收藏"
            return
        }

        var updated = settings.bookmarks
        let bookmarkID = editingBookmarkID
            ?? updated.first(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
                    == URL(fileURLWithPath: path).standardizedFileURL.path
            })?.id
            ?? UUID()
        let bookmark = Bookmark(id: bookmarkID, name: name, path: path, folder: folder)
        if let index = updated.firstIndex(where: { $0.id == bookmarkID }) {
            updated[index] = bookmark
        } else {
            updated.append(bookmark)
        }
        settings.bookmarks = updated
        if !settings.bookmarkFolderOrder.contains(folder) {
            settings.bookmarkFolderOrder = settings.bookmarkFolderOrder + [folder]
        }
        refreshBookmarkUI()
        statusLabel.stringValue = "收藏已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.updateStatus(selection: self.contentController.selectedItems)
        }
        cancelBookmarkEditor()
    }

    @objc private func removeBookmarkFromEditor() {
        guard let editingBookmarkID else { return }
        var bookmarks = settings.bookmarks
        bookmarks.removeAll { $0.id == editingBookmarkID }
        settings.bookmarks = bookmarks
        refreshBookmarkUI()
        statusLabel.stringValue = "已取消收藏"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.updateStatus(selection: self.contentController.selectedItems)
        }
        cancelBookmarkEditor()
    }

    private func showBookmarkFolderEditor(_ folder: String) {
        let alert = NSAlert()
        alert.messageText = "重命名收藏夹"
        alert.informativeText = "收藏夹名称："
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "删除收藏夹")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: folder)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        editingBookmarkFolderName = folder
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != folder else {
                editingBookmarkFolderName = nil
                return
            }
            var bookmarks = settings.bookmarks
            for i in bookmarks.indices where bookmarks[i].folder == folder {
                bookmarks[i].folder = newName
            }
            settings.bookmarks = bookmarks
            settings.bookmarkFolderOrder = settings.bookmarkFolderOrder.map { $0 == folder ? newName : $0 }
            refreshBookmarkUI()
        } else if response == .alertSecondButtonReturn {
            var bookmarks = settings.bookmarks
            bookmarks.removeAll { $0.folder == folder }
            settings.bookmarks = bookmarks
            settings.bookmarkFolderOrder = settings.bookmarkFolderOrder.filter { $0 != folder }
            refreshBookmarkUI()
        }
        editingBookmarkFolderName = nil
    }

    @objc func openBookmarkMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else {
            NSSound.beep()
            return
        }
        navigate(to: URL(fileURLWithPath: path))
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: SettingsWindowController.didChangeNotification,
            object: nil
        )
    }

    @objc private func settingsChanged() {
        reloadContents()
        chromeHeader.rebuildNewItemTypes(settings.newItemTypes)
        refreshBookmarkUI()
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            reloadContents()
            return
        }
        let urls = FileOperations.search(in: currentDirectory, query: query)
        let items = urls.compactMap(FileItem.from)
        contentController.setItems(items)
        updateStatus(selection: [])
    }

    // MARK: - Path editing

    private func beginPathEditing() {
        guard !isEditingPath else {
            window?.makeFirstResponder(pathField)
            return
        }
        isEditingPath = true
        pathField.stringValue = currentDirectory.path
        breadcrumbStack.isHidden = true
        pathField.isHidden = false
        window?.makeFirstResponder(pathField)
        installPathEditClickMonitor()
        DispatchQueue.main.async { [weak self] in
            self?.pathField.currentEditor()?.selectAll(nil)
        }
    }

    private func endPathEditing(commit: Bool) {
        removePathEditClickMonitor()
        hideAutocomplete()
        guard isEditingPath else { return }
        if commit {
            let raw = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                navigate(to: URL(fileURLWithPath: expanded))
            } else if FileManager.default.fileExists(atPath: expanded) {
                let file = URL(fileURLWithPath: expanded)
                pendingSelectURLs = [file]
                navigate(to: file.deletingLastPathComponent())
            } else {
                NSSound.beep()
            }
        }
        isEditingPath = false
        pathField.isHidden = true
        breadcrumbStack.isHidden = false
        updatePathChrome()
        if window?.firstResponder === pathField || window?.firstResponder is NSText {
            window?.makeFirstResponder(contentController.view)
        }
    }

    private func installPathEditClickMonitor() {
        removePathEditClickMonitor()
        pathEditClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isEditingPath else { return event }
            if self.isEventInsidePathEditingUI(event) {
                return event
            }
            self.endPathEditing(commit: false)
            return event
        }
    }

    private func removePathEditClickMonitor() {
        if let pathEditClickMonitor {
            NSEvent.removeMonitor(pathEditClickMonitor)
            self.pathEditClickMonitor = nil
        }
    }

    private func isEventInsidePathEditingUI(_ event: NSEvent) -> Bool {
        if let panel = autocompletePanel, panel.isVisible, event.window === panel {
            return true
        }
        guard let window = event.window, window === self.window else { return false }
        let location = event.locationInWindow
        let fieldFrame = pathField.convert(pathField.bounds, to: nil)
        if fieldFrame.insetBy(dx: -2, dy: -2).contains(location) {
            return true
        }
        return false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === pathField {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                _ = applySelectedAutocomplete(partial: false)
                endPathEditing(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                endPathEditing(commit: false)
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                selectAutocomplete(offset: 1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                selectAutocomplete(offset: -1)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                _ = applySelectedAutocomplete(partial: true)
                return true
            }
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        let candidates = FileOperations.pathAutocomplete(for: pathField.stringValue)
        showAutocomplete(candidates)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        if isEditingPath {
            endPathEditing(commit: false)
        }
    }

    private func showAutocomplete(_ candidates: [String]) {
        autocompleteCandidates = candidates
        guard !candidates.isEmpty, let window else {
            hideAutocomplete()
            return
        }

        if autocompletePanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .controlBackgroundColor
            panel.hasShadow = true

            let scroll = NSScrollView(frame: panel.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            let table = NSTableView(frame: scroll.bounds)
            let column = NSTableColumn(identifier: .init("path"))
            column.width = 380
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = 22
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.action = #selector(autocompleteClicked)
            scroll.documentView = table
            panel.contentView?.addSubview(scroll)

            autocompletePanel = panel
            autocompleteList = table
        }

        autocompleteList?.reloadData()
        let fieldRect = pathField.convert(pathField.bounds, to: nil)
        let screenRect = window.convertToScreen(fieldRect)
        let height = min(CGFloat(candidates.count) * 22 + 8, 180)
        autocompletePanel?.setFrame(
            NSRect(x: screenRect.minX, y: screenRect.minY - height - 2, width: max(screenRect.width, 320), height: height),
            display: true
        )
        autocompletePanel?.orderFront(nil)
    }

    private func hideAutocomplete() {
        autocompletePanel?.orderOut(nil)
        autocompleteCandidates = []
    }

    @objc private func autocompleteClicked() {
        guard let row = autocompleteList?.selectedRow, row >= 0, row < autocompleteCandidates.count else { return }
        pathField.stringValue = autocompleteCandidates[row]
        endPathEditing(commit: true)
    }

    private func selectAutocomplete(offset: Int) {
        guard let table = autocompleteList, !autocompleteCandidates.isEmpty else { return }
        let next = max(0, min(autocompleteCandidates.count - 1, table.selectedRow + offset))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        pathField.stringValue = autocompleteCandidates[next]
    }

    /// Apply highlighted autocomplete candidate. `partial` keeps editing with the chosen path.
    @discardableResult
    private func applySelectedAutocomplete(partial: Bool) -> Bool {
        guard !autocompleteCandidates.isEmpty else { return false }
        let row = max(0, autocompleteList?.selectedRow ?? 0)
        guard autocompleteCandidates.indices.contains(row) else { return false }
        pathField.stringValue = autocompleteCandidates[row]
        if !partial {
            hideAutocomplete()
        }
        return true
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        hideAutocomplete()
    }
}

/// Path bar that enters edit mode when clicking empty space (Finder-like).
final class ClickablePathBarView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Stack that lets empty-area clicks fall through to the path bar.
final class PassThroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Custom history row: path left, gray time right-aligned.
final class HistoryMenuItemView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView()
    private var isHighlighted = false
    private weak var enclosingItem: NSMenuItem?

    init(path: String, time: String, icon: NSImage?, isCurrent: Bool, pathWidth: CGFloat, timeWidth: CGFloat, rowWidth: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 24))

        iconView.image = icon
        iconView.image?.size = NSSize(width: 16, height: 16)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.stringValue = path
        pathLabel.font = .systemFont(ofSize: 13)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.stringValue = time
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        checkView.image = isCurrent
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            : nil
        checkView.contentTintColor = .labelColor
        checkView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkView)
        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            checkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 12),
            checkView.heightAnchor.constraint(equalToConstant: 12),

            iconView.leadingAnchor.constraint(equalTo: checkView.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.widthAnchor.constraint(equalToConstant: pathWidth),

            timeLabel.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 16),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: timeWidth)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        enclosingItem = enclosingMenuItem
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
            pathLabel.textColor = .white
            timeLabel.textColor = NSColor.white.withAlphaComponent(0.75)
            checkView.contentTintColor = .white
        } else {
            pathLabel.textColor = .labelColor
            timeLabel.textColor = .secondaryLabelColor
            checkView.contentTintColor = .labelColor
        }
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem ?? enclosingItem,
              let menu = item.menu else { return }
        menu.cancelTracking()
        if let action = item.action, let target = item.target {
            _ = (target as AnyObject).perform(action, with: item)
        } else if let action = item.action {
            NSApp.sendAction(action, to: nil, from: item)
        }
    }
}

/// Breadcrumb segment with a light hover background.
final class BreadcrumbButton: NSButton {
    private var tracking: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        isTransparent = false
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 12)
        focusRingType = .none
        sendAction(on: [.leftMouseUp])
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 10
        size.height = max(size.height, 20)
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            // Light hover — works in light & dark appearance
            let fill = NSColor.labelColor.withAlphaComponent(0.08)
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Path-bar chevron: hover highlight + click to list directory contents.
final class BreadcrumbChevronButton: NSView {
    var directoryPath = ""
    var onClick: (() -> Void)?

    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3

        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "目录内容")!
        imageView.image = image
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 8),
            imageView.heightAnchor.constraint(equalToConstant: 10),
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        imageView.contentTintColor = .secondaryLabelColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        imageView.contentTintColor = .tertiaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        // Consume so path bar doesn't treat this as empty-area click.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
        super.draw(dirtyRect)
    }
}

extension BrowserWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        autocompleteCandidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        cell.textField?.stringValue = autocompleteCandidates[row]
        cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return cell
    }
}
