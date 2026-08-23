import AppKit
import Carbon
import CoreText
import Darwin
import ServiceManagement
import UniformTypeIdentifiers

private enum AXSafe {
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

final class FinderPathApp: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard
    private let instanceLock = SingleInstanceLock()
    // NSAppleScript is neither safe to run concurrently nor safe to invoke
    // again while its Apple-event loop is re-entering the application.
    // Keep all execution on the main thread and defer async requests.
    private var isExecutingAppleScript = false
    private var deferredAppleScripts: [String] = []
    private var reentrantAppleScriptSkipCount = 0
    private var lastReentrantAppleScriptLogAt = Date.distantPast
    private let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private var panel: NSPanel!
    private var settingsPanel: NSPanel?
    private var historyPanel: NSPanel?
    private var toolbarMenuPanel: NSPanel?
    private var bookmarkEditorPanel: NSPanel?
    private var bookmarkFolderEditorPanel: NSPanel?
    private weak var toolbarMenuSourceButton: NSButton?
    private var closeFailurePanel: NSPanel?
    private var historyListView: HistoryListView?
    private var historyBackgroundView: NSView?
    private var toolbarMenuRows: [ToolbarMenuRowView] = []
    private var pathField: PathTextField!
    private var breadcrumbScrollView: NSScrollView!
    private var breadcrumbStack: NSStackView!
    private var autocompletePanel: NSPanel?
    private var autocompleteListView: AutocompleteListView?
    private var autocompleteCandidates: [String] = []
    private var autocompleteSelectedIndex = 0
    private var cachedFinderPath: String?
    private var backgroundView: NSView!
    private var closeButton: NSButton!
    private var closeOthersButton: NSButton!
    private var closeAllButton: NSButton!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var parentButton: NSButton!
    private var historyButton: NSButton!
    private var bookmarkButton: NSButton!
    private var searchButton: NSButton!
    private var searchField: NSTextField!
    private var searchFieldWidthConstraint: NSLayoutConstraint!
    private var searchCenterYConstraint: NSLayoutConstraint!
    private var searchButtonCenterYConstraint: NSLayoutConstraint!
    private var isSearchExpanded = false
    private var isEditingSearch = false
    private var searchPanel: NSPanel?
    private var searchListView: AutocompleteListView?
    private var searchCandidates: [URL] = []
    private var searchSelectedIndex = -1
    private var searchRootPath: String = ""
    private var searchTotalMatchCount = 0
    private var searchUpdateWorkItem: DispatchWorkItem?
    private var extensionButton: NSButton!
    private var copyPathButton: NSButton!
    private var goPathButton: NSButton!
    private var bookmarkFolderStack: NSStackView!
    private var bookmarksToolbar: NSStackView!
    private var secondToolbar: NSStackView!
    private var bookmarkRowSeparator: NSView!
    private var bookmarksEmptyLabel: NSTextField?
    private var bookmarkFolderButtons: [BookmarkFolderButton] = []
    private weak var bookmarkFolderField: NSTextField?
    private weak var bookmarkFolderPicker: NSPopUpButton?
    private weak var bookmarkNameField: NSTextField?
    private weak var bookmarkPathField: NSTextField?
    private weak var bookmarkFolderNameField: NSTextField?
    private var editingBookmarkID: UUID?
    private var editingBookmarkFolderName: String?
    private weak var settingsBackgroundColorField: NSTextField?
    private weak var settingsBackgroundColorWell: NSColorWell?
    private weak var settingsDropdownColorField: NSTextField?
    private weak var settingsDropdownColorWell: NSColorWell?
    private var iconButtons: [NSButton] = []
    private var secondToolbarButtons: [NSButton] = []
    private var newItemButtons: [NSButton] = []
    private var newItemButtonWidthConstraints: [NSLayoutConstraint] = []
    private var settingsNewItemTypeFields: [NSTextField] = []
    private var buttonHandlers: [NSButton: () -> Void] = [:]
    private var stackCenterYConstraint: NSLayoutConstraint!
    private var fieldCenterYConstraint: NSLayoutConstraint!
    private var pathFieldHeightConstraint: NSLayoutConstraint!
    private var historyCenterYConstraint: NSLayoutConstraint!
    private var bookmarkCenterYConstraint: NSLayoutConstraint!
    private var secondToolbarBottomToContentConstraint: NSLayoutConstraint!
    private var secondToolbarBottomToBookmarksConstraint: NSLayoutConstraint!
    private var bookmarksToolbarBottomConstraint: NSLayoutConstraint!
    private var bookmarksToolbarLeadingToContentConstraint: NSLayoutConstraint!
    private var bookmarksToolbarLeadingToOpsConstraint: NSLayoutConstraint!
    private var bookmarksToolbarCenterYToOpsConstraint: NSLayoutConstraint!
    private var iconButtonHeightConstraints: [NSLayoutConstraint] = []
    private var followTimer: Timer?
    private var autoAttachTimer: Timer?
    private var renameHotKeyResumeTimer: Timer?
    private var donationReminderTimer: Timer?
    private var donationPanel: NSPanel?
    /// Wait until FinderPathBar panel is visible before first tip popup.
    private var donationAwaitingFPPanel = false
    private var isCheckingForUpdates = false
    private weak var settingsUpdateStatusLabel: NSTextField?
    private weak var settingsUpdateProgress: NSProgressIndicator?
    private var updateProgressPanel: NSPanel?
    private var updateProgressIndicator: NSProgressIndicator?
    private var updateProgressLabel: NSTextField?
    private var updateDownloader: UpdateDownloadController?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var isHotKeyHandlerInstalled = false
    private var mouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var mouseEventTap: CFMachPort?
    private var mouseEventTapRunLoopSource: CFRunLoopSource?
    private var keyEventTap: CFMachPort?
    private var keyEventTapRunLoopSource: CFRunLoopSource?
    private var longPressWorkItem: DispatchWorkItem?
    private var lastButtonDispatchAt: Date?
    private var suppressNextToolbarMouseUp = false
    private var lastNewItemURL: URL?
    private var lastNewItemExtensionName: String?
    private var lastNewItemCreatedAt = Date.distantPast
    private var hasPendingCut = false
    private var pendingCutURLs: [URL] = []
    /// Main-thread flag for the CGEvent tap. Never read NSWorkspace from the tap
    /// thread — it lags on app switch and the first ⌘V in the other app is eaten.
    private var finderKeyTapArmed = false
    private var lastTrashedItems: [TrashedItemRecord] = []
    private var undoButton: NSButton?
    private var lastGlobalMouseDownAt = Date.distantPast
    private var lastGlobalMouseDownPoint = NSPoint.zero
    private var isDraggingPanel = false
    private var isFinderRenameHotKeysSuspended = false
    private var dragStartMouseLocation = NSPoint.zero
    private var dragStartFinderBounds: FinderBounds?
    private var isFreezingDuringFinderMouseDrag = false
    private var isLiveTrackingFinderGeometry = false
    private var isEditingPath = false
    private var isNavigatingHistory = false
    private var manuallyHidden = false
    private var isHidingOrDetachingPanel = false
    private var pendingFinderReattachWorkItem: DispatchWorkItem?
    private var processActivity: NSObjectProtocol?
    private var suppressAutoHideUntil: Date?
    private var suppressAutoAttachUntil: Date?
    private var ignoreNextSyncRecordUntil: Date?
    private var attachedFinderWindowID: Int?
    /// When true, the path bar is attached to another app's Open/Save file dialog.
    private var isFileDialogMode = false
    private var attachedFileDialogPID: pid_t?
    private var lastFileDialogBounds: NSRect?
    private var lastFileDialogPathSyncAt = Date.distantPast
    private var isNavigatingFileDialog = false
    /// Cancels in-flight Open/Save dialog navigation when a newer jump starts.
    private var fileDialogNavigationToken = 0
    private var lastMainContentBounds: NSRect?
    private var lastMainContentWindowID: Int?
    private var lastFinderWindowBounds: NSRect?
    private var pendingCollapsedSidebarContent: NSRect?
    private var finderWindowUnavailableSince: Date?
    /// Path bar was ordered out because Finder showed Replace / Get Info / etc.
    private var hiddenForFinderUtilityDialog = false
    private var lastPathSyncAt = Date.distantPast
    private var lastContentBoundsSyncAt = Date.distantPast
    private var history: [HistoryEntry] = []
    private var historyIndex = -1
    private var visibleHistory: [HistoryEntry] = []

    private var bookmarks: [Bookmark] {
        get {
            if let data = defaults.data(forKey: "bookmarks"),
               let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) {
                return bookmarks
            }
            let legacyPaths = defaults.stringArray(forKey: "bookmarkedPaths") ?? []
            return legacyPaths.map {
                Bookmark(folder: localized("Bookmarks", "收藏夹"), name: URL(fileURLWithPath: $0).lastPathComponent, path: $0)
            }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "bookmarks")
            }
            defaults.removeObject(forKey: "bookmarkedPaths")
        }
    }

    private var bookmarkFolderOrder: [String] {
        get { defaults.stringArray(forKey: "bookmarkFolderOrder") ?? [] }
        set { defaults.set(newValue, forKey: "bookmarkFolderOrder") }
    }

    private let barHeight: CGFloat = 33
    private let secondToolbarHeight: CGFloat = 28
    /// Bookmarks always share the second (ops) toolbar row.
    private var bookmarksOnThirdRow: Bool { false }
    private var effectiveBookmarksToolbarHeight: CGFloat { 0 }
    private let defaultNewItemButtonTypes = ["dir", "txt", "docx", "xlsx", "R", "py"]
    /// Six toolbar shortcuts: `dir` = folder, otherwise file extension (e.g. `md`, `csv`).
    private var newItemButtonTypes: [String] {
        get { normalizedNewItemButtonTypes(defaults.stringArray(forKey: "newItemButtonTypes") ?? []) }
        set { defaults.set(normalizedNewItemButtonTypes(newValue), forKey: "newItemButtonTypes") }
    }
    /// Path-row centerY from content bottom (ops row + optional bookmarks row below it).
    private var pathRowCenterYFromBottom: CGFloat {
        -(effectiveBookmarksToolbarHeight + secondToolbarHeight + barHeight / 2)
    }
    private let maxPathLines: CGFloat = 3
    private var verticalGap: CGFloat { 0 }
    private var horizontalInset: CGFloat { 0 }
    private var iconSize: CGFloat { CGFloat(defaults.double(forKey: "iconSize") == 0 ? 20 : defaults.double(forKey: "iconSize")) }
    private var iconHeight: CGFloat { CGFloat(defaults.double(forKey: "iconHeight") == 0 ? 24 : defaults.double(forKey: "iconHeight")) }
    private var pathFontSize: CGFloat { CGFloat(defaults.double(forKey: "pathFontSize") == 0 ? 15 : defaults.double(forKey: "pathFontSize")) }
    private var textYOffset: CGFloat { CGFloat(defaults.double(forKey: "textYOffset")) }
    private var panelHeightOffset: CGFloat { CGFloat(defaults.double(forKey: "panelHeightOffset")) }
    private var backgroundColorHex: String { defaults.string(forKey: "backgroundColor") ?? "#f1f2f3" }
    private var dropdownBackgroundColorHex: String { defaults.string(forKey: "dropdownBackgroundColor") ?? "#ffffff" }
    private var languageCode: String {
        if let stored = defaults.string(forKey: "languageCode") {
            return stored
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
    }
    private var isChineseLanguage: Bool { languageCode == "zh" }
    private var launchesAtLogin: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return defaults.bool(forKey: "launchAtLogin")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            // A second instance would register the same global hot keys and
            // send competing commands to Finder. Exit before setting up any
            // observers or event handlers.
            AppLogger.shared.logSync("duplicateInstance exiting")
            NSApp.terminate(nil)
            return
        }
        AppLogger.shared.installCrashHandlers()
        AppLogger.shared.log("applicationDidFinishLaunching version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        NSApp.setActivationPolicy(.accessory)
        // Menu-bar agents must not be jetsam'd / auto-terminated when the path
        // panel is ordered out (opening Excel/WPS hides all FP windows).
        ProcessInfo.processInfo.disableAutomaticTermination("FinderPathBar status item agent")
        if processActivity == nil {
            processActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
                reason: "FinderPathBar stays running while Finder is used"
            )
        }
        _ = ensureAccessibilityPermission(prompt: true)
        migrateDefaultSizingIfNeeded()
        configureStatusItem()
        configurePanel()
        updateHotKeyRegistrationForFrontmostApp()
        startAutoAttachFinder()
        startDonationReminderIfNeeded()
        scheduleMonthlyUpdateCheckIfNeeded()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.log("applicationWillTerminate")
        stopDonationReminder()
        hideDonationPanel()
        stopAutoAttachFinder()
        stopFollowingFinder()
        stopMouseMonitor()
        stopKeyEventTap()
        stopRenameHotKeyResumeTimer()
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
    }

    private func configureStatusItem() {
        let menuIcon = NSImage(named: "AppIcon")
        menuIcon?.size = NSSize(width: 20, height: 20)
        menuIcon?.isTemplate = false
        statusItem.button?.image = menuIcon
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .medium)
        statusItem.button?.toolTip = "FinderPathBar"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: localized("Show Path Bar", "显示地址栏"), action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("Hide Path Bar", "隐藏地址栏"), action: #selector(hidePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("Settings", "设置"), action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("Donate", "捐赠支持"), action: #selector(showDonationPanelFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("Open Log", "打开日志"), action: #selector(openLogFile), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: localized("Quit FinderPathBar", "退出 FinderPathBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func migrateDefaultSizingIfNeeded() {
        let versionKey = "sizingDefaultsVersion"
        guard defaults.integer(forKey: versionKey) < 1 else { return }
        let storedIcon = defaults.object(forKey: "iconSize") as? Double
        let storedText = defaults.object(forKey: "pathFontSize") as? Double
        if storedIcon == nil || storedIcon == 11 {
            defaults.set(20.0, forKey: "iconSize")
        }
        if storedText == nil || storedText == 13 {
            defaults.set(15.0, forKey: "pathFontSize")
        }
        defaults.set(1, forKey: versionKey)
    }

    private func localized(_ english: String, _ chinese: String) -> String {
        isChineseLanguage ? chinese : english
    }

    private func configurePanel() {
        panel = AddressBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false

        backgroundView = NSView(frame: panel.contentView?.bounds ?? .zero)
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false

        pathField = PathTextField()
        pathField.isBordered = false
        pathField.isBezeled = false
        pathField.drawsBackground = false
        pathField.isEditable = true
        pathField.isSelectable = true
        pathField.cell?.wraps = true
        pathField.cell?.isScrollable = false
        pathField.cell?.lineBreakMode = .byCharWrapping
        pathField.focusRingType = .none
        pathField.font = .monospacedSystemFont(ofSize: pathFontSize, weight: .regular)
        pathField.textColor = .labelColor
        pathField.placeholderString = "/Users/..."
        pathField.delegate = self
        pathField.target = self
        pathField.action = #selector(openEnteredPath)
        pathField.toolTip = "Focus Address Bar (Cmd+L)"
        pathField.beginEditingHandler = { [weak self] in
            self?.beginPathEditing()
        }
        pathField.doubleClickHandler = { [weak self] index in
            self?.openPathComponent(at: index)
        }
        pathField.translatesAutoresizingMaskIntoConstraints = false

        // Breadcrumb UI kept out of the default chrome; path field is the primary address bar.
        let breadcrumbStack = NSStackView()
        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.spacing = 2
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        self.breadcrumbStack = breadcrumbStack

        let breadcrumbScrollView = BreadcrumbScrollView(frame: .zero)
        breadcrumbScrollView.drawsBackground = false
        breadcrumbScrollView.hasHorizontalScroller = false
        breadcrumbScrollView.hasVerticalScroller = false
        breadcrumbScrollView.documentView = breadcrumbStack
        breadcrumbScrollView.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbScrollView.isHidden = true
        self.breadcrumbScrollView = breadcrumbScrollView
        pathField.isHidden = false

        let closeButton = makeIconButton(title: "x") { [weak self] in self?.closeFinderAndHide() }
        let closeOthersButton = makeIconButton(title: "Xo") { [weak self] in self?.closeOtherFinderWindows() }
        let closeAllButton = makeIconButton(title: "Xa") { [weak self] in self?.closeAllFinderWindows() }
        let settingsButton = makeIconButton(title: "⚙") { [weak self] in self?.showSettings() }
        let backButton = makeIconButton(title: "<") { [weak self] in self?.goBack() }
        let forwardButton = makeIconButton(title: ">") { [weak self] in self?.goForward() }
        let parentButton = makeIconButton(title: "^") { [weak self] in self?.goToParentDirectory() }
        let historyButton = HistoryButton(title: "⌄", target: nil, action: nil)
        let bookmarkButton = makeIconButton(title: "") { [weak self] in self?.toggleBookmark() }
        configureIconButton(historyButton)
        closeButton.toolTip = "Close Finder Window (Cmd+W)"
        closeOthersButton.toolTip = localized("Close other Finder windows", "关闭其他 Finder 窗口")
        closeAllButton.toolTip = localized("Close all Finder windows", "关闭所有 Finder 窗口")
        applyCloseGlyph(closeButton, suffix: nil)
        applyCloseGlyph(closeOthersButton, suffix: "o")
        applyCloseGlyph(closeAllButton, suffix: "a")
        settingsButton.toolTip = "Settings"
        backButton.toolTip = "Back (Cmd+←)"
        forwardButton.toolTip = "Forward (Cmd+→)"
        parentButton.toolTip = "Parent Folder (Cmd+↑)"
        historyButton.toolTip = "History (Cmd+↓)"
        bookmarkButton.toolTip = localized("Add bookmark", "收藏当前地址")
        self.closeButton = closeButton
        self.closeOthersButton = closeOthersButton
        self.closeAllButton = closeAllButton
        self.backButton = backButton
        self.forwardButton = forwardButton
        self.parentButton = parentButton
        self.historyButton = historyButton
        self.bookmarkButton = bookmarkButton

        let searchField = NSTextField(string: "")
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 12, weight: .regular)
        searchField.textColor = .labelColor
        searchField.placeholderString = localized("Name/folder keywords (AND)…", "搜文件名与文件夹名；空格=同时匹配")
        searchField.delegate = self
        searchField.isHidden = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        self.searchField = searchField

        let searchButton = makeIconButton(title: "") { [weak self] in self?.toggleFolderSearch() }
        searchButton.toolTip = localized("Search folder tree; space = AND (Cmd+F)", "搜索当前文件夹树；空格分隔为同时匹配 (Cmd+F)")
        self.searchButton = searchButton
        updateSearchButtonAppearance()

        historyButton.mouseDownHandler = { [weak self] in
            guard let self, self.shouldDispatchButtonClick() else { return }
            self.lastButtonDispatchAt = Date()
            self.suppressNextToolbarMouseUp = true
            DispatchQueue.main.async { [weak self] in
                self?.toggleHistoryMenu()
                self?.suppressNextToolbarMouseUp = false
            }
        }
        buttonHandlers[historyButton] = { [weak self] in
            self?.toggleHistoryMenu()
        }
        iconButtons = [closeButton, closeOthersButton, closeAllButton, settingsButton, backButton, forwardButton, parentButton, historyButton, bookmarkButton, searchButton]

        let buttonStack = NSStackView(views: [closeButton, closeOthersButton, closeAllButton, settingsButton, backButton, forwardButton, parentButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 3
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let copyPathButton = makeOperationIconButton(
            symbolName: "doc.on.clipboard",
            fallbackTitle: "CPth",
            tooltip: localized("Copy selected paths, or the current folder path", "复制选中路径，或当前文件夹路径"),
            pointSize: 12.5
        ) { [weak self] in
            self?.copyFinderPathsToPasteboard()
        }
        self.copyPathButton = copyPathButton
        let goPathButton = makeOperationIconButton(
            symbolName: "arrow.right.doc.on.clipboard",
            fallbackTitle: "goPth",
            tooltip: localized("Go to path from clipboard", "跳转到剪切板中的路径"),
            pointSize: 12.5
        ) { [weak self] in
            self?.goToClipboardPath()
        }
        self.goPathButton = goPathButton

        let pathActionStack = NSStackView(views: [copyPathButton, goPathButton])
        pathActionStack.orientation = .horizontal
        pathActionStack.spacing = 2
        pathActionStack.alignment = .centerY
        pathActionStack.translatesAutoresizingMaskIntoConstraints = false

        let newItemButtons: [NSButton] = {
            newItemButtonWidthConstraints.removeAll()
            return (0..<6).map { makeNewItemButton(index: $0) }
        }()
        self.newItemButtons = newItemButtons
        let separator = makeToolbarSeparator()
        let renameButton = makeOperationIconButton(image: makeRenameIconImage(), fallbackTitle: "Rn", tooltip: "Rename (F2)") { [weak self] in
            self?.performFinderOperation(.rename)
        }
        let openButton = makeOperationIconButton(image: makeOpenBookIconImage(), fallbackTitle: "Op", tooltip: "Open (Enter)") { [weak self] in
            self?.performFinderOperation(.open)
        }
        let copyButton = makeOperationIconButton(symbolName: "doc.on.doc", fallbackTitle: "Cp", tooltip: "Copy (Ctrl+C)", pointSize: 12.5) { [weak self] in
            self?.performFinderOperation(.copy)
        }
        let cutButton = makeOperationIconButton(symbolName: "scissors", fallbackTitle: "Ct", tooltip: localized("Cut (Cmd+X), then Paste to move (Cmd+V)", "剪切（⌘X），再粘贴移动（⌘V）")) { [weak self] in
            self?.performFinderOperation(.cut)
        }
        let pasteButton = makeOperationIconButton(image: makePasteIconImage(), fallbackTitle: "Pst", tooltip: "Paste / Move Cut Items (Cmd+V)") { [weak self] in
            self?.performFinderOperation(.paste)
        }
        let deleteButton = makeOperationIconButton(symbolName: "trash", fallbackTitle: "Del", tooltip: localized("Delete to Trash", "移到废纸篓")) { [weak self] in
            self?.performFinderOperation(.delete)
        }
        let undoButton = makeOperationIconButton(symbolName: "arrow.uturn.backward", fallbackTitle: "Und", tooltip: localized("Undo Trash", "撤销删除（从废纸篓还原）")) { [weak self] in
            self?.undoLastTrash()
        }
        self.undoButton = undoButton
        let separator2 = makeToolbarSeparator()
        let extensionButton = makeOperationButton(title: "Ext", tooltip: localized("Annotate comments with file extensions", "用扩展名填写注释")) { [weak self] in
            self?.annotateExtensionsAndSort()
        }
        self.extensionButton = extensionButton
        secondToolbarButtons = newItemButtons + [renameButton, openButton, copyButton, cutButton, pasteButton, deleteButton, undoButton, extensionButton, copyPathButton, goPathButton]

        let bookmarkFolderStack = NSStackView()
        bookmarkFolderStack.orientation = .horizontal
        bookmarkFolderStack.spacing = 3
        bookmarkFolderStack.alignment = .centerY
        bookmarkFolderStack.translatesAutoresizingMaskIntoConstraints = false
        self.bookmarkFolderStack = bookmarkFolderStack

        let bookmarksEmptyLabel = NSTextField(labelWithString: localized("No bookmarks — click ★ to add", "暂无收藏 · 点 ★ 添加"))
        bookmarksEmptyLabel.font = .systemFont(ofSize: 11, weight: .regular)
        bookmarksEmptyLabel.textColor = .secondaryLabelColor
        bookmarksEmptyLabel.isHidden = true
        bookmarksEmptyLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bookmarksEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let bookmarkRowSeparator = makeToolbarSeparator()
        bookmarkRowSeparator.isHidden = true
        self.bookmarkRowSeparator = bookmarkRowSeparator

        let bookmarksToolbar = NSStackView(views: [bookmarkRowSeparator, bookmarkFolderStack, bookmarksEmptyLabel])
        bookmarksToolbar.orientation = .horizontal
        bookmarksToolbar.spacing = 6
        bookmarksToolbar.alignment = .centerY
        bookmarksToolbar.translatesAutoresizingMaskIntoConstraints = false
        self.bookmarksToolbar = bookmarksToolbar

        let secondToolbar = NSStackView(views: newItemButtons + [separator, renameButton, openButton, copyButton, cutButton, pasteButton, deleteButton, undoButton, separator2, extensionButton])
        secondToolbar.orientation = .horizontal
        secondToolbar.spacing = 1
        secondToolbar.alignment = .centerY
        secondToolbar.translatesAutoresizingMaskIntoConstraints = false
        self.secondToolbar = secondToolbar

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backgroundView)
        content.addSubview(buttonStack)
        content.addSubview(pathActionStack)
        content.addSubview(pathField)
        content.addSubview(breadcrumbScrollView)
        content.addSubview(historyButton)
        content.addSubview(bookmarkButton)
        content.addSubview(searchField)
        content.addSubview(searchButton)
        content.addSubview(secondToolbar)
        content.addSubview(bookmarksToolbar)
        panel.contentView = content

        stackCenterYConstraint = buttonStack.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: pathRowCenterYFromBottom)
        fieldCenterYConstraint = pathField.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: pathRowCenterYFromBottom + textYOffset)
        pathFieldHeightConstraint = pathField.heightAnchor.constraint(equalToConstant: 25)
        historyCenterYConstraint = historyButton.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: pathRowCenterYFromBottom)
        bookmarkCenterYConstraint = bookmarkButton.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: pathRowCenterYFromBottom)
        searchCenterYConstraint = searchField.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: pathRowCenterYFromBottom + textYOffset)
        searchButtonCenterYConstraint = searchButton.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: pathRowCenterYFromBottom)
        searchFieldWidthConstraint = searchField.widthAnchor.constraint(equalToConstant: 0)
        iconButtonHeightConstraints = [
            closeButton.heightAnchor.constraint(equalToConstant: iconHeight),
            closeOthersButton.heightAnchor.constraint(equalToConstant: iconHeight),
            closeAllButton.heightAnchor.constraint(equalToConstant: iconHeight),
            settingsButton.heightAnchor.constraint(equalToConstant: iconHeight),
            backButton.heightAnchor.constraint(equalToConstant: iconHeight),
            forwardButton.heightAnchor.constraint(equalToConstant: iconHeight),
            parentButton.heightAnchor.constraint(equalToConstant: iconHeight),
            historyButton.heightAnchor.constraint(equalToConstant: iconHeight),
            bookmarkButton.heightAnchor.constraint(equalToConstant: iconHeight),
            searchButton.heightAnchor.constraint(equalToConstant: iconHeight)
        ]

        secondToolbarBottomToContentConstraint = secondToolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3)
        secondToolbarBottomToBookmarksConstraint = secondToolbar.bottomAnchor.constraint(equalTo: bookmarksToolbar.topAnchor, constant: -4)
        bookmarksToolbarBottomConstraint = bookmarksToolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3)
        bookmarksToolbarLeadingToContentConstraint = bookmarksToolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 7)
        bookmarksToolbarLeadingToOpsConstraint = bookmarksToolbar.leadingAnchor.constraint(equalTo: secondToolbar.trailingAnchor, constant: 4)
        bookmarksToolbarCenterYToOpsConstraint = bookmarksToolbar.centerYAnchor.constraint(equalTo: secondToolbar.centerYAnchor)

        let baseConstraints: [NSLayoutConstraint] = [
            backgroundView.topAnchor.constraint(equalTo: content.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 7),
            stackCenterYConstraint,

            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeOthersButton.widthAnchor.constraint(equalToConstant: 26),
            closeAllButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.widthAnchor.constraint(equalToConstant: 22),
            backButton.widthAnchor.constraint(equalToConstant: 22),
            forwardButton.widthAnchor.constraint(equalToConstant: 22),
            parentButton.widthAnchor.constraint(equalToConstant: 22),

            pathActionStack.leadingAnchor.constraint(equalTo: buttonStack.trailingAnchor, constant: 4),
            pathActionStack.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: pathRowCenterYFromBottom),
            copyPathButton.widthAnchor.constraint(equalToConstant: 24),
            copyPathButton.heightAnchor.constraint(equalToConstant: 22),
            goPathButton.widthAnchor.constraint(equalToConstant: 24),
            goPathButton.heightAnchor.constraint(equalToConstant: 22),

            pathField.leadingAnchor.constraint(equalTo: pathActionStack.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: historyButton.leadingAnchor, constant: -6),
            fieldCenterYConstraint,
            pathFieldHeightConstraint,

            breadcrumbScrollView.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            breadcrumbScrollView.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            breadcrumbScrollView.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            breadcrumbScrollView.heightAnchor.constraint(equalTo: pathField.heightAnchor),

            historyButton.trailingAnchor.constraint(equalTo: bookmarkButton.leadingAnchor, constant: -2),
            historyCenterYConstraint,
            historyButton.widthAnchor.constraint(equalToConstant: 22),

            bookmarkButton.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -2),
            bookmarkCenterYConstraint,
            bookmarkButton.widthAnchor.constraint(equalToConstant: 22),

            searchField.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -2),
            searchCenterYConstraint,
            searchFieldWidthConstraint,
            searchField.heightAnchor.constraint(equalToConstant: 22),

            searchButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -7),
            searchButtonCenterYConstraint,
            searchButton.widthAnchor.constraint(equalToConstant: 22),

            secondToolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 7),
            secondToolbar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -7),
            secondToolbar.heightAnchor.constraint(equalToConstant: 22),

            bookmarksToolbar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -7),
            bookmarksToolbar.heightAnchor.constraint(equalToConstant: 22),

            separator.widthAnchor.constraint(equalToConstant: 3),
            separator.heightAnchor.constraint(equalToConstant: 16),
            renameButton.widthAnchor.constraint(equalToConstant: 28),
            openButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            cutButton.widthAnchor.constraint(equalToConstant: 24),
            pasteButton.widthAnchor.constraint(equalToConstant: 26),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            undoButton.widthAnchor.constraint(equalToConstant: 24),
            separator2.widthAnchor.constraint(equalToConstant: 3),
            separator2.heightAnchor.constraint(equalToConstant: 16),
            extensionButton.widthAnchor.constraint(equalToConstant: 28),
            bookmarkRowSeparator.widthAnchor.constraint(equalToConstant: 3),
            bookmarkRowSeparator.heightAnchor.constraint(equalToConstant: 16)
        ]
        NSLayoutConstraint.activate(baseConstraints)
        NSLayoutConstraint.activate(iconButtonHeightConstraints)
        NSLayoutConstraint.activate(newItemButtonWidthConstraints)

        self.bookmarksEmptyLabel = bookmarksEmptyLabel
        applyBookmarksToolbarLayout()
        applyNewItemButtonTypes()

        applyAppearanceSettings()
        updateBookmarkButton()
        rebuildBookmarkFolderButtons()
        updatePathChromeVisibility()
        updateUndoButtonState()
    }

    private func applyBookmarksToolbarLayout() {
        guard secondToolbar != nil, bookmarksToolbar != nil else { return }
        let onThirdRow = bookmarksOnThirdRow

        secondToolbarBottomToContentConstraint.isActive = !onThirdRow
        secondToolbarBottomToBookmarksConstraint.isActive = onThirdRow
        bookmarksToolbarBottomConstraint.isActive = onThirdRow
        bookmarksToolbarLeadingToContentConstraint.isActive = onThirdRow
        bookmarksToolbarLeadingToOpsConstraint.isActive = !onThirdRow
        bookmarksToolbarCenterYToOpsConstraint.isActive = !onThirdRow
        // Same row as Ext: gray divider after Ext, before bookmarks.
        bookmarkRowSeparator?.isHidden = onThirdRow

        stackCenterYConstraint.constant = pathRowCenterYFromBottom
        historyCenterYConstraint.constant = pathRowCenterYFromBottom
        bookmarkCenterYConstraint.constant = pathRowCenterYFromBottom
        searchButtonCenterYConstraint?.constant = pathRowCenterYFromBottom
        searchCenterYConstraint?.constant = pathRowCenterYFromBottom + textYOffset
        fieldCenterYConstraint.constant = pathRowCenterYFromBottom + textYOffset
        panel.contentView?.layoutSubtreeIfNeeded()
        updatePanelFrame()
    }

    private func makeIconButton(title: String, handler: @escaping () -> Void) -> NSButton {
        let button = NonActivatingButton(title: title, target: nil, action: nil)
        button.mouseDownHandler = { [weak self] in
            guard let self, self.shouldDispatchButtonClick() else { return }
            self.lastButtonDispatchAt = Date()
            self.suppressNextToolbarMouseUp = true
            // Defer so AppleScript cannot re-enter the run loop mid-mouseDown
            // and accidentally deliver mouseUp to bookmark buttons.
            DispatchQueue.main.async { [weak self] in
                handler()
                self?.suppressNextToolbarMouseUp = false
            }
        }
        buttonHandlers[button] = handler
        configureIconButton(button)
        return button
    }

    private func makeNewItemButton(index: Int) -> NSButton {
        let types = newItemButtonTypes
        let title = (index < types.count ? types[index] : defaultNewItemButtonTypes[index])
        let button = NonActivatingButton(title: title, target: nil, action: nil)
        button.tag = index
        button.toolTip = localized(
            "\(title): single click to create, double click to create and open",
            "\(title)：单击新建，双击新建并打开（dir=文件夹）"
        )
        button.mouseDownEventHandler = { [weak self] event in
            guard let self else { return }
            guard self.shouldDispatchButtonClick() else { return }
            self.lastButtonDispatchAt = Date()
            self.suppressNextToolbarMouseUp = true
            let clickCount = event.clickCount
            let buttonIndex = index
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let type = self.newItemButtonTypes[buttonIndex]
                self.handleNewItemButtonClick(
                    extensionName: self.extensionName(forNewItemButtonType: type),
                    clickCount: clickCount
                )
                self.suppressNextToolbarMouseUp = false
            }
        }
        configureTextToolButton(button)
        let width = newItemButtonPreferredWidth(for: title, font: button.font)
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        newItemButtonWidthConstraints.append(widthConstraint)
        return button
    }

    private func normalizedNewItemButtonTypes(_ raw: [String]) -> [String] {
        var result: [String] = []
        for i in 0..<6 {
            let fallback = defaultNewItemButtonTypes[i]
            let value: String
            if i < raw.count {
                value = raw[i]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else {
                value = fallback
            }
            result.append(value.isEmpty ? fallback : value)
        }
        return result
    }

    private func extensionName(forNewItemButtonType type: String) -> String? {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if trimmed.isEmpty || lowered == "dir" || trimmed == "文件夹" || lowered == "folder" {
            return nil
        }
        return trimmed
    }

    private func newItemButtonPreferredWidth(for title: String, font: NSFont?) -> CGFloat {
        let resolvedFont = font ?? .systemFont(ofSize: max(10, pathFontSize - 1), weight: .medium)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: resolvedFont]).width)
        return max(16, min(56, textWidth + 8))
    }

    private func applyNewItemButtonTypes() {
        let types = newItemButtonTypes
        for (index, button) in newItemButtons.enumerated() where index < types.count {
            let title = types[index]
            button.title = title
            button.toolTip = localized(
                "\(title): single click to create, double click to create and open",
                "\(title)：单击新建，双击新建并打开（dir=文件夹）"
            )
            if index < newItemButtonWidthConstraints.count {
                newItemButtonWidthConstraints[index].constant = newItemButtonPreferredWidth(for: title, font: button.font)
            }
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        updatePanelFrame()
    }

    private func makeOperationButton(title: String, tooltip: String, handler: @escaping () -> Void) -> NSButton {
        let button = NonActivatingButton(title: title, target: nil, action: nil)
        button.toolTip = tooltip
        button.mouseDownHandler = { [weak self] in
            guard let self, self.shouldDispatchButtonClick() else { return }
            self.lastButtonDispatchAt = Date()
            self.suppressNextToolbarMouseUp = true
            DispatchQueue.main.async { [weak self] in
                handler()
                self?.suppressNextToolbarMouseUp = false
            }
        }
        buttonHandlers[button] = handler
        configureTextToolButton(button)
        return button
    }

    private func makeOperationIconButton(symbolName: String, fallbackTitle: String, tooltip: String, pointSize: CGFloat? = nil, handler: @escaping () -> Void) -> NSButton {
        let button = makeOperationButton(title: fallbackTitle, tooltip: tooltip, handler: handler)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: pointSize ?? max(12, pathFontSize + 1), weight: .regular)) {
            configureOperationImage(image, on: button)
        }
        return button
    }

    private func makeOperationIconButton(image: NSImage, fallbackTitle: String, tooltip: String, handler: @escaping () -> Void) -> NSButton {
        let button = makeOperationButton(title: fallbackTitle, tooltip: tooltip, handler: handler)
        configureOperationImage(image, on: button)
        return button
    }

    private func configureOperationImage(_ image: NSImage, on button: NSButton) {
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
    }

    private func makeRenameIconImage() -> NSImage {
        let size = NSSize(width: 25, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        let stroke = NSColor.labelColor
        stroke.setStroke()

        let box = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 19, height: 11), xRadius: 2.5, yRadius: 2.5)
        box.lineWidth = 1.35
        box.stroke()

        let text = "abc" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: stroke
        ]
        text.draw(at: NSPoint(x: 4.5, y: 4), withAttributes: attributes)

        let caret = NSBezierPath()
        caret.lineWidth = 1.25
        caret.move(to: NSPoint(x: 21.8, y: 1.5))
        caret.line(to: NSPoint(x: 21.8, y: 14.5))
        caret.move(to: NSPoint(x: 19.2, y: 1.5))
        caret.line(to: NSPoint(x: 24.4, y: 1.5))
        caret.move(to: NSPoint(x: 19.2, y: 14.5))
        caret.line(to: NSPoint(x: 24.4, y: 14.5))
        caret.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func makePasteIconImage() -> NSImage {
        let size = NSSize(width: 24, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()

        let stroke = NSColor.labelColor
        stroke.setStroke()

        let clipboard = NSBezierPath()
        clipboard.lineWidth = 1.1
        clipboard.move(to: NSPoint(x: 3, y: 4))
        clipboard.line(to: NSPoint(x: 3, y: 14.8))
        clipboard.line(to: NSPoint(x: 6.8, y: 14.8))
        clipboard.move(to: NSPoint(x: 12.8, y: 14.8))
        clipboard.line(to: NSPoint(x: 17, y: 14.8))
        clipboard.line(to: NSPoint(x: 17, y: 10.2))
        clipboard.stroke()

        let clip = NSBezierPath()
        clip.lineWidth = 1.1
        clip.move(to: NSPoint(x: 6.8, y: 14.8))
        clip.line(to: NSPoint(x: 6.8, y: 16.8))
        clip.line(to: NSPoint(x: 9.5, y: 16.8))
        clip.line(to: NSPoint(x: 9.5, y: 17.8))
        clip.line(to: NSPoint(x: 12.8, y: 17.8))
        clip.line(to: NSPoint(x: 12.8, y: 16.8))
        clip.line(to: NSPoint(x: 15.5, y: 16.8))
        clip.line(to: NSPoint(x: 15.5, y: 14.8))
        clip.close()
        clip.stroke()

        let page = NSBezierPath()
        page.lineWidth = 1.1
        page.move(to: NSPoint(x: 10.2, y: 2))
        page.line(to: NSPoint(x: 10.2, y: 10.4))
        page.line(to: NSPoint(x: 16.2, y: 10.4))
        page.line(to: NSPoint(x: 20.6, y: 6))
        page.line(to: NSPoint(x: 20.6, y: 2))
        page.close()
        page.stroke()

        let fold = NSBezierPath()
        fold.lineWidth = 1.0
        fold.move(to: NSPoint(x: 16.2, y: 10.4))
        fold.line(to: NSPoint(x: 16.2, y: 6))
        fold.line(to: NSPoint(x: 20.6, y: 6))
        fold.stroke()

        for y in [7.2, 5.0, 3.0] as [CGFloat] {
            let line = NSBezierPath()
            line.lineWidth = 0.95
            line.move(to: NSPoint(x: 12.5, y: y))
            line.line(to: NSPoint(x: 18.8, y: y))
            line.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func makeOpenBookIconImage() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let stroke = NSColor.labelColor
        stroke.setStroke()

        let leftPage = NSBezierPath()
        leftPage.lineWidth = 1.25
        leftPage.move(to: NSPoint(x: 2, y: 3))
        leftPage.curve(to: NSPoint(x: 10.7, y: 2.4), controlPoint1: NSPoint(x: 5.2, y: 4.2), controlPoint2: NSPoint(x: 8, y: 3.1))
        leftPage.line(to: NSPoint(x: 10.7, y: 14.7))
        leftPage.curve(to: NSPoint(x: 2, y: 15.2), controlPoint1: NSPoint(x: 8.2, y: 14.1), controlPoint2: NSPoint(x: 5.2, y: 14.8))
        leftPage.close()
        leftPage.stroke()

        let rightPage = NSBezierPath()
        rightPage.lineWidth = 1.25
        rightPage.move(to: NSPoint(x: 11.3, y: 2.4))
        rightPage.curve(to: NSPoint(x: 20, y: 3), controlPoint1: NSPoint(x: 14, y: 3.1), controlPoint2: NSPoint(x: 16.8, y: 4.2))
        rightPage.line(to: NSPoint(x: 20, y: 15.2))
        rightPage.curve(to: NSPoint(x: 11.3, y: 14.7), controlPoint1: NSPoint(x: 16.8, y: 14.8), controlPoint2: NSPoint(x: 13.8, y: 14.1))
        rightPage.close()
        rightPage.stroke()

        let spine = NSBezierPath()
        spine.lineWidth = 1.1
        spine.move(to: NSPoint(x: 11, y: 2.2))
        spine.line(to: NSPoint(x: 11, y: 15))
        spine.stroke()

        for y in [11.5, 8.8] as [CGFloat] {
            let leftLine = NSBezierPath()
            leftLine.lineWidth = 0.9
            leftLine.move(to: NSPoint(x: 4.3, y: y))
            leftLine.line(to: NSPoint(x: 8.5, y: y - 0.3))
            leftLine.stroke()

            let rightLine = NSBezierPath()
            rightLine.lineWidth = 0.9
            rightLine.move(to: NSPoint(x: 13.5, y: y - 0.3))
            rightLine.line(to: NSPoint(x: 17.7, y: y))
            rightLine.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func makeToolbarSeparator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.62, alpha: 0.9).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func configureTextToolButton(_ button: NSButton) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .systemFont(ofSize: pathFontSize, weight: .regular)
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.sendAction(on: [.leftMouseUp])
    }

    private func handleNewItemButtonClick(extensionName: String?, clickCount: Int) {
        if clickCount >= 2 {
            if let recentURL = lastNewItemURL,
               lastNewItemExtensionName == extensionName,
               Date().timeIntervalSince(lastNewItemCreatedAt) <= NSEvent.doubleClickInterval + 0.2 {
                openCreatedItem(recentURL, isDirectory: extensionName == nil)
            } else {
                _ = createNewItem(extensionName: extensionName, openAfterCreate: true)
            }
            return
        }

        if let createdURL = createNewItem(extensionName: extensionName, openAfterCreate: false) {
            lastNewItemURL = createdURL
            lastNewItemExtensionName = extensionName
            lastNewItemCreatedAt = Date()
        }
    }

    private func configureIconButton(_ button: NSButton) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .systemFont(ofSize: iconSize, weight: .semibold)
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.sendAction(on: [.leftMouseUp])
    }

    /// Draw the shared close "x" (same size/baseline on x, Xo, Xa). Optional o/a sits
    /// on the x ink's bottom edge, slightly to the right.
    private func applyCloseGlyph(_ button: NSButton, suffix: String?) {
        let xFont = NSFont.systemFont(ofSize: iconSize, weight: .semibold)
        let suffixSize = max(7, iconSize * 0.62)
        let suffixFont = NSFont.systemFont(ofSize: suffixSize, weight: .medium)
        let canvasHeight = max(iconHeight, 16)

        func lineAndImageBounds(_ string: String, font: NSFont) -> (CTLine, CGRect) {
            let attr = NSAttributedString(string: string, attributes: [
                .font: font,
                .foregroundColor: NSColor.black
            ])
            let line = CTLineCreateWithAttributedString(attr)
            return (line, CTLineGetImageBounds(line, nil))
        }

        let (xLine, xBounds) = lineAndImageBounds("x", font: xFont)
        let suffixLineAndBounds: (CTLine, CGRect)? = suffix.map { lineAndImageBounds($0, font: suffixFont) }
        let padding: CGFloat = 1
        let gap: CGFloat = 3.4
        // Pin x to the same vertical slot in every button so the three x glyphs match.
        let xBaseline = CGPoint(
            x: padding - xBounds.minX,
            y: (canvasHeight - xBounds.height) / 2 - xBounds.minY
        )
        var maxX = xBaseline.x + xBounds.maxX
        var suffixBaseline = CGPoint.zero
        if let (_, suffixBounds) = suffixLineAndBounds {
            suffixBaseline = CGPoint(
                x: xBaseline.x + xBounds.maxX + gap - suffixBounds.minX,
                y: xBaseline.y + xBounds.minY - suffixBounds.minY
            )
            maxX = max(maxX, suffixBaseline.x + suffixBounds.maxX)
        }
        let canvas = NSSize(width: ceil(maxX + padding), height: canvasHeight)
        let image = NSImage(size: canvas, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: xBaseline.x, y: xBaseline.y)
            CTLineDraw(xLine, ctx)
            ctx.restoreGState()
            if let (suffixLine, _) = suffixLineAndBounds {
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: suffixBaseline.x, y: suffixBaseline.y)
                CTLineDraw(suffixLine, ctx)
                ctx.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
    }

    private func showToolbarMenu(from sourceButton: NSButton, items: [ToolbarMenuItem]) {
        if toolbarMenuPanel?.isVisible == true {
            if toolbarMenuSourceButton === sourceButton {
                hideToolbarMenu()
                return
            }
            hideToolbarMenu()
        }
        let rowHeight: CGFloat = 26
        let itemFont = NSFont.systemFont(ofSize: pathFontSize, weight: .regular)
        let maxTextWidth = items
            .map { ($0.title as NSString).size(withAttributes: [.font: itemFont]).width }
            .max() ?? 44
        let width = ceil(maxTextWidth + 28)
        let height = CGFloat(items.count) * rowHeight
        let buttonRect = sourceButton.convert(sourceButton.bounds, to: nil)
        let buttonScreenRect = panel.convertToScreen(buttonRect)
        let frame = NSRect(x: buttonScreenRect.minX, y: buttonScreenRect.minY - height - 2, width: width, height: height)

        let menuPanel = ToolbarMenuPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        menuPanel.isFloatingPanel = true
        menuPanel.level = .modalPanel
        menuPanel.backgroundColor = .clear
        menuPanel.isOpaque = false
        menuPanel.hasShadow = true
        menuPanel.isReleasedWhenClosed = false
        menuPanel.acceptsMouseMovedEvents = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.white.cgColor
        stack.layer?.cornerRadius = 6

        toolbarMenuRows.removeAll()
        for item in items {
            let row = ToolbarMenuRowView(title: item.title, font: itemFont)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.onSelect = item.action
            row.onEdit = item.editAction
            toolbarMenuRows.append(row)
            stack.addArrangedSubview(row)
        }

        let content = NSView()
        content.addSubview(stack)
        menuPanel.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        toolbarMenuPanel = menuPanel
        toolbarMenuSourceButton = sourceButton
        menuPanel.rows = toolbarMenuRows
        menuPanel.orderFrontRegardless()
    }

    private func hideToolbarMenu() {
        toolbarMenuPanel?.orderOut(nil)
        toolbarMenuSourceButton = nil
        toolbarMenuRows.removeAll()
    }

    private func updateToolbarMenuPanelFrame() {
        guard let toolbarMenuPanel, toolbarMenuPanel.isVisible else { return }
        toolbarMenuPanel.level = panel.level
    }

    private func registerHotKey() {
        guard hotKeyRefs.isEmpty else { return }
        registerHotKey(keyCode: UInt32(kVK_ANSI_G), id: 1)
        registerHotKey(keyCode: UInt32(kVK_ANSI_L), id: 2)
        registerHotKey(keyCode: UInt32(kVK_LeftArrow), id: 3)
        registerHotKey(keyCode: UInt32(kVK_RightArrow), id: 4)
        registerHotKey(keyCode: UInt32(kVK_UpArrow), id: 5)
        registerHotKey(keyCode: UInt32(kVK_DownArrow), id: 6)
        registerHotKey(keyCode: UInt32(kVK_ANSI_W), id: 7)
        registerHotKey(keyCode: UInt32(kVK_F2), id: 8, modifiers: 0)
        registerHotKey(keyCode: UInt32(kVK_ANSI_F), id: 9)
        // Do NOT register Cmd/Ctrl+C/X/V as Carbon hotkeys. Those steal the
        // key from every app until Finder-deactivation is observed — so the
        // first ⌘V after leaving Finder (typically pasting files copied there)
        // is swallowed. Clipboard shortcuts are handled by the Finder-only
        // CGEvent tap instead.

        if !isHotKeyHandlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let userData, let event else { return noErr }
                let app = Unmanaged<FinderPathApp>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                DispatchQueue.main.async { app.handleHotKey(id: hotKeyID.id) }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
            isHotKeyHandlerInstalled = true
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
    }

    private func updateHotKeyRegistrationForFrontmostApp() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bundleID == "com.apple.finder", settingsPanel?.isVisible != true {
            registerHotKey()
            if panel.isVisible {
                startKeyEventTap()
            } else {
                finderKeyTapArmed = false
                stopKeyEventTap()
            }
        } else {
            // Disarm before tearing the tap down so an in-flight key is not swallowed.
            finderKeyTapArmed = false
            unregisterHotKeys()
            stopKeyEventTap()
        }
    }

    private func registerHotKey(keyCode: UInt32, id: UInt32, modifiers: UInt32 = UInt32(cmdKey)) {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("Fndr"), id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr, let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
        }
    }

    private func handleHotKey(id: UInt32) {
        AppLogger.shared.log("hotKey id=\(id)")
        guard shouldHandleHotKey(id) else {
            // Global hot-key registration is removed when Finder loses focus,
            // but its activation notification can arrive after a key event.
            // Never let that short race redirect another app's shortcuts to Finder.
            AppLogger.shared.log("hotKey ignored outside Finder id=\(id)")
            unregisterHotKeys()
            return
        }
        switch id {
        case 1:
            togglePanel()
        case 2:
            focusPathField()
        case 3:
            goBack()
        case 4:
            goForward()
        case 5:
            goToParentDirectory()
        case 6:
            toggleHistoryMenu()
        case 7:
            closeFinderAndHide()
        case 8:
            performFinderOperation(.rename)
        case 9:
            toggleFolderSearch()
        case 12:
            handleEnterKeyForFinder()
        case 15, 16:
            // Cmd+X / Ctrl+X → cut (move on paste). Ignore while renaming inline.
            if isFinderRenameHotKeysSuspended || isFinderRenamingItem() {
                return
            }
            performFinderOperation(.cut)
        case 17, 18:
            // Cmd+V / Ctrl+V → paste (or move if cut is pending).
            if isFinderRenameHotKeysSuspended || isFinderRenamingItem() {
                return
            }
            performFinderOperation(.paste)
        case 19:
            // Cmd+C → real copy; clears any pending cut.
            if isFinderRenameHotKeysSuspended || isFinderRenamingItem() {
                return
            }
            performFinderOperation(.copy)
        default:
            break
        }
    }

    private func shouldHandleHotKey(_ id: UInt32) -> Bool {
        if isFinderFrontmost {
            return true
        }

        // Cmd+F must toggle search closed while the search field is focused
        // (FinderPathBar is frontmost in that state).
        if id == 9, isFinderPathBarFrontmost, panel.isVisible, isSearchExpanded {
            return true
        }

        // When the address bar / search field is key, FinderPathBar is frontmost so normal
        // text editing shortcuts must remain available to its text field.
        let isEditingChrome = isFinderPathBarFrontmost && panel.isVisible && (isEditingPath || isEditingSearch)
        return isEditingChrome && (id == 13 || id == 14)
    }

    @objc private func togglePanel() {
        AppLogger.shared.log("togglePanel visible=\(panel.isVisible)")
        panel.isVisible ? hidePanel() : showPanel()
    }

    @objc private func showPanel() {
        AppLogger.shared.log("showPanel finderFrontmost=\(isFinderFrontmost) fpFrontmost=\(isFinderPathBarFrontmost) attachedID=\(attachedFinderWindowID.map(String.init) ?? "nil")")
        guard isFinderFrontmost || (isFinderPathBarFrontmost && attachedFinderWindowID != nil) else { return }
        manuallyHidden = false
        presentPanel(focusAddressBar: false, createFinderWindow: isFinderFrontmost)
    }

    @objc private func hidePanel() {
        AppLogger.shared.log("hidePanel")
        manuallyHidden = true
        hidePanelAutomatically(force: true)
    }

    private func focusPathField() {
        manuallyHidden = false
        if !panel.isVisible {
            presentPanel(focusAddressBar: false, createFinderWindow: false)
        } else {
            refreshPathFromFinder()
            updatePanelFrame()
            startFollowingFinder()
            startMouseMonitor()
        }
        beginPathEditing()
    }

    private func presentPanel(focusAddressBar: Bool, createFinderWindow: Bool) {
        if createFinderWindow, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" {
            activateFinder()
        }
        if createFinderWindow {
            openFinderWindowIfNeeded()
        }
        // Prefer AX path sync here. AppleScript during app-switch reattach has
        // repeatedly crashed (SIGSEGV) when Excel/WPS/PPT become frontmost.
        refreshPathFromFinder(allowAppleScript: false)
        updatePanelFrame()
        if focusAddressBar {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(pathField)
        } else {
            endPathEditing()
            panel.orderFrontRegardless()
        }
        startFollowingFinder()
        startMouseMonitor()
        startKeyEventTap()
        maybeShowDonationAfterFPAppeared()
        // Key CGEvent tap handles Return for open / rename-confirm while Finder is frontmost.
    }

    private func hidePanelAutomatically(force: Bool = false) {
        // Critical: endFolderSearch → updatePanelFrame → hidePanelAutomatically
        // used to recurse until stack overflow (SIGSEGV) when leaving Finder.
        guard !isHidingOrDetachingPanel else { return }
        guard force || !isAutoHideSuppressed else { return }
        guard force || !isNavigatingHistory else { return }
        AppLogger.shared.log("hidePanelAutomatically force=\(force)")
        isHidingOrDetachingPanel = true
        defer { isHidingOrDetachingPanel = false }
        endFolderSearch(collapse: true, updateLayout: false)
        panel.orderOut(nil)
        hideHistoryPanel()
        hideToolbarMenu()
        hideAutocompletePanel()
        hideSearchPanel()
        stopFollowingFinder()
    }

    /// Hide the path bar when leaving Finder. Keep teardown minimal and deferred
    /// so we never cancel event sources mid-callback (that produced libdispatch
    /// "monitored resource vanished" + SIGSEGV when opening WPS/Excel).
    private func detachFromFinderForOtherApp() {
        guard !isHidingOrDetachingPanel else { return }
        isHidingOrDetachingPanel = true
        defer { isHidingOrDetachingPanel = false }

        clearFileDialogMode()
        hiddenForFinderUtilityDialog = false
        pendingFinderReattachWorkItem?.cancel()
        pendingFinderReattachWorkItem = nil
        stopFollowingFinder()
        isFreezingDuringFinderMouseDrag = false
        isLiveTrackingFinderGeometry = false
        endFolderSearch(collapse: true, updateLayout: false)
        panel.orderOut(nil)
        hideHistoryPanel()
        hideToolbarMenu()
        hideAutocompletePanel()
        hideSearchPanel()
        finderKeyTapArmed = false
        unregisterHotKeys()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only tear monitors down if Finder is still not frontmost.
            guard !self.isFinderFrontmost, !self.isFileDialogMode else { return }
            self.stopMouseMonitor()
            self.stopKeyEventTap()
        }
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        updateHotKeyRegistrationForFrontmostApp()

        // Leaving FP (Finder or another app) dismisses folder search.
        // Use updateLayout:false — full layout here re-enters hide while another
        // app is already frontmost and previously overflowed the stack.
        if isSearchExpanded, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            endFolderSearch(collapse: true, updateLayout: false)
        }

        // Switching to Finder must always leave file-dialog mode, even while
        // auto-hide is suppressed (dialog sync keeps refreshing that suppress).
        if app.bundleIdentifier == "com.apple.finder" {
            leaveFileDialogModeForFinder()
            manuallyHidden = false
            pendingFinderReattachWorkItem?.cancel()
            // Delay reattach so document apps finish activating and Finder settles.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.isFinderFrontmost else { return }
                AppLogger.shared.log("activeApp finder — reattach")
                self.startAutoAttachFinder()
                self.autoAttachIfNeeded()
            }
            pendingFinderReattachWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            return
        }

        guard !isAutoHideSuppressed else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            if let dialog = findFrontFileDialog() {
                AppLogger.shared.log("activeApp fileDialog app=\(app.bundleIdentifier ?? app.localizedName ?? "?")")
                enterFileDialogMode(dialog)
            } else {
                AppLogger.shared.log("activeApp hidePanel app=\(app.bundleIdentifier ?? app.localizedName ?? "?")")
                clearFileDialogMode()
                detachFromFinderForOtherApp()
            }
        }
    }

    @objc private func showSettings() {
        AppLogger.shared.log("showSettings")
        suppressAutoHide()
        hideHistoryPanel(clearSuppression: false)
        hideToolbarMenu()
        unregisterHotKeys()
        settingsPanel?.orderOut(nil)
        settingsPanel = makeSettingsPanel()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel?.center()
        settingsPanel?.level = .modalPanel
        settingsPanel?.makeKeyAndOrderFront(nil)
        updatePanelLevelForCurrentApp()
    }

    @objc private func openLogFile() {
        AppLogger.shared.log("openLogFile")
        // Reveal in Finder first so the Documents log is easy to find; opening
        // the file directly in an editor can lock/replace it mid-write.
        AppLogger.shared.revealInFinder()
    }

    @objc private func openEnteredPath() {
        suppressAutoHide()
        hideAutocompletePanel()
        let input = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.shared.log("openEnteredPath input=\(input)")
        guard !input.isEmpty else {
            endPathEditing()
            refocusAttachedFinderWindow(activateFinder: true)
            return
        }

        let expanded = (input as NSString).expandingTildeInPath
        let path = expanded.hasPrefix("/") ? expanded : (NSHomeDirectory() as NSString).appendingPathComponent(expanded)
        endPathEditing()
        if isFileDialogMode {
            navigateFileDialog(to: path, source: "address-bar")
            return
        }
        navigateFinder(to: path, source: "address-bar")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refocusAttachedFinderWindow(activateFinder: true)
        }
    }

    @discardableResult
    private func createNewItem(extensionName: String?, openAfterCreate: Bool) -> URL? {
        AppLogger.shared.log("createNewItem ext=\(extensionName ?? "dir") openAfterCreate=\(openAfterCreate)")
        guard let directory = directoryURLFromPathField() ?? currentFinderDirectoryURL() else {
            AppLogger.shared.log("createNewItem failed: no current directory")
            NSSound.beep()
            return nil
        }

        do {
            let createdURL: URL
            if let ext = extensionName {
                createdURL = uniqueURL(in: directory, baseName: "未命名", extensionName: ext)
                if let binary = defaultBinaryFileContents(for: ext) {
                    try binary.write(to: createdURL, options: .atomic)
                } else {
                    let contents = defaultFileContents(for: ext, directory: directory)
                    if contents.isEmpty {
                        guard FileManager.default.createFile(atPath: createdURL.path, contents: Data()) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    } else {
                        try contents.write(to: createdURL, atomically: true, encoding: .utf8)
                    }
                }
            } else {
                createdURL = uniqueURL(in: directory, baseName: "未命名文件夹", extensionName: nil)
                try FileManager.default.createDirectory(at: createdURL, withIntermediateDirectories: false)
            }

            notifyFinderAboutCreatedItem(createdURL, in: directory)
            AppLogger.shared.log("createNewItem success path=\(createdURL.path)")
            if openAfterCreate {
                if extensionName == nil {
                    openCreatedItem(createdURL, isDirectory: true)
                    refreshPathFromFinder()
                    updatePanelFrame()
                } else {
                    selectCreatedFinderItem(createdURL)
                    openCreatedItem(createdURL, isDirectory: false)
                }
            } else {
                selectCreatedFinderItem(createdURL)
            }
            return createdURL
        } catch {
            AppLogger.shared.log("createNewItem error=\(error.localizedDescription)")
            NSSound.beep()
            showCloseFailure(localized("Create failed", "创建失败"))
            return nil
        }
    }

    private func notifyFinderAboutCreatedItem(_ url: URL, in directory: URL) {
        NSWorkspace.shared.noteFileSystemChanged(url.path)
        NSWorkspace.shared.noteFileSystemChanged(directory.path)
    }

    /// Reveal + select in the attached Finder window. Finder often needs a beat
    /// after changing folders before selection sticks.
    private func revealAndSelectFinderItem(_ url: URL, activateFinder: Bool = true) {
        AppLogger.shared.log("revealAndSelectFinderItem path=\(url.path)")
        if activateFinder {
            refocusAttachedFinderWindow(activateFinder: true)
        }
        selectFinderItem(url, after: 0.08)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        selectFinderItem(url, after: 0.28)
        selectFinderItem(url, after: 0.45)
    }

    /// After FileManager creates an item, Finder often needs a beat to show it.
    /// Reveal + select so the new file/folder is highlighted in the current window.
    private func selectCreatedFinderItem(_ url: URL) {
        revealAndSelectFinderItem(url)
    }

    private func openCreatedItem(_ url: URL, isDirectory: Bool) {
        if isDirectory {
            guard setFinderTarget(url) else {
                NSSound.beep()
                showCloseFailure(localized("Couldn't open Finder location", "无法打开 Finder 位置"))
                return
            }
            pathField.stringValue = url.path
            updateBookmarkButton()
            recordHistory(url.path)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func annotateExtensionsAndSort() {
        AppLogger.shared.log("Ext start")
        // Immediate feedback so a slow/hung script never looks like a dead click.
        extensionButton?.title = "..."
        showCloseFailure("Ext...")
        suppressAutoHide(duration: 8.0)
        guard ensureAccessibilityPermission(prompt: true) else {
            AppLogger.shared.log("Ext blocked: accessibility permission missing")
            extensionButton?.title = "Ext"
            NSSound.beep()
            showCloseFailure(localized("Accessibility permission is not enabled", "辅助功能权限未生效"))
            return
        }
        endFolderSearch(collapse: true)
        endPathEditing()
        refocusAttachedFinderWindow(activateFinder: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.annotateExtensionsWithFinderCommentsAndSort()
            DispatchQueue.main.async {
                self.extensionButton?.title = "Ext"
                if let result {
                    AppLogger.shared.log("Ext result=\(result)")
                    self.showCloseFailure(result)
                } else {
                    AppLogger.shared.log("Ext failed: nil result")
                    self.showCloseFailure(self.localized("Ext failed", "Ext失败"))
                }
                self.refreshPathFromFinder()
                self.updatePanelFrame()
            }
        }
    }

    private func annotateExtensionsWithFinderCommentsAndSort() -> String? {
        // User-provided Ext flow:
        // 1) list view + detect Comments header (shallow scroll-area scan)
        // 2) if missing → ⌘J, check 注释, close View Options
        // 3) write comments (dir / extension / unix / none) — no sort
        let script = #"""
        osascript <<'APPLESCRIPT'

        tell application "Finder"
        if (count of Finder windows) is 0 then
        return "ERROR: Finder 没有打开的文件夹窗口"
        end if

        set frontW to front Finder window

        try
        set originalTarget to target of frontW as alias
        on error
        return "ERROR: 无法获取当前 Finder 目录"
        end try

        set current view of frontW to list view
        activate
        end tell


        tell application "System Events"
        tell process "Finder"
        set frontmost to true

        set w to missing value

        repeat 10 times
        try
        set w to first window whose subrole is "AXStandardWindow"
        end try

        if w is not missing value then exit repeat
            delay 0.02
        end repeat
            
            if w is missing value then
        return "ERROR: 没有找到 Finder 标准窗口"
        end if


        set sa to missing value

        repeat with e1 in UI elements of w
        try
        repeat with e2 in UI elements of e1
        try
        repeat with e3 in UI elements of e2
        try
        if role of e3 is "AXScrollArea" then
        set sa to e3
        exit repeat
            end if
        end try
        end repeat
            
            if sa is not missing value then exit repeat
                end try
        end repeat
            
            if sa is not missing value then exit repeat
                end try
        end repeat
            
            
            if sa is missing value then
        return "ERROR: 没有找到 Finder 文件列表滚动区"
        end if


        set hasComment to false

        repeat with e in UI elements of sa
        try
        if role of e is "AXButton" then
        set d to description of e

        if d is "注释" or ¬
        d starts with "注释," or ¬
        d is "Comments" or ¬
        d starts with "Comments," then

        set hasComment to true
        exit repeat
            end if
        end if
        end try
        end repeat
            
            
            if hasComment is false then

        keystroke "j" using {command down}

        set viewWindow to missing value
        set commentBox to missing value


        repeat 20 times

        repeat with ww in windows
        try

        repeat with e1 in UI elements of ww

        try
        if role of e1 is "AXCheckBox" then
        set n to name of e1

        if n is "注释" or n is "Comments" then
        set viewWindow to ww
        set commentBox to e1
        exit repeat
            end if
        end if
        end try


        try
        if role of e1 is "AXGroup" then

        repeat with e2 in UI elements of e1
        try
        if role of e2 is "AXCheckBox" then
        set n to name of e2

        if n is "注释" or n is "Comments" then
        set viewWindow to ww
        set commentBox to e2
        exit repeat
            end if
        end if
        end try
        end repeat
            
            end if
        end try


        if commentBox is not missing value then
        exit repeat
            end if

        end repeat
            
            
            if commentBox is not missing value then
        exit repeat
            end if

        end try
        end repeat
            
            
            if commentBox is not missing value then
        exit repeat
            end if

        delay 0.02
        end repeat
            
            
            if commentBox is missing value then
        return "ERROR: Cmd+J 中没有找到“注释”复选框"
        end if


        if value of commentBox is 0 then
        click commentBox
        end if


        if viewWindow is not missing value then
        try
        set closeButton to first UI element of viewWindow whose subrole is "AXCloseButton"
        click closeButton
        on error
        try
        repeat with e in UI elements of viewWindow
        try
        if subrole of e is "AXCloseButton" then
        perform action "AXPress" of e
        exit repeat
            end if
        end try
        end repeat
            end try
        end try
        end if

        end if
        end tell
        end tell


        tell application "Finder"

        if (count of Finder windows) is 0 then
        return "ERROR: Finder 窗口已经关闭"
        end if

        set frontW to front Finder window

        try
        set originalTarget to target of frontW as alias
        on error
        return "ERROR: 无法重新获取当前 Finder 目录"
        end try


        set dirCount to 0
        set extensionCount to 0
        set unixCount to 0
        set noneCount to 0
        set errorCount to 0


        set itemList to every item of originalTarget


        repeat with f in itemList

        try
        set itemClass to class of f


        if itemClass is folder then

        set comment of f to "dir"
        set dirCount to dirCount + 1

        else
            
            set ext to name extension of f

        if ext is not missing value and ext is not "" then

        set comment of f to ext
        set extensionCount to extensionCount + 1

        else
            
            set filePath to POSIX path of (f as alias)

        try
        do shell script "/usr/bin/test -x " & quoted form of filePath

        set comment of f to "unix"
        set unixCount to unixCount + 1

        on error

        set comment of f to "none"
        set noneCount to noneCount + 1

        end try

        end if

        end if

        on error
        set errorCount to errorCount + 1
        end try

        end repeat
            
            
            return "完成" & linefeed & ¬
        "文件夹: " & dirCount & linefeed & ¬
        "扩展名文件: " & extensionCount & linefeed & ¬
        "Unix 可执行文件: " & unixCount & linefeed & ¬
        "无扩展名普通文件: " & noneCount & linefeed & ¬
        "处理失败: " & errorCount

        end tell

        APPLESCRIPT
        """#

        let result = runShellScript(script)
        let output = [result.output, result.error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        AppLogger.shared.log("Ext script exit=\(result.exitCode) output=\(output)")

        if result.exitCode == 0 {
            if output.hasPrefix("ERROR:") {
                return String(output.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return output.isEmpty ? localized("Ext done", "Ext完成") : output
        }
        let short = output
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let range = short.range(of: "ERROR:") {
            return String(short[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return localized("Ext failed — check Automation permission for Finder", "Ext失败 — 请检查对 Finder 的自动化权限")
    }

    @discardableResult
    private func restoreFinderListColumnWidths(
        name: Int,
        modificationDate: Int,
        creationDate: Int,
        size: Int,
        kind: Int,
        label: Int,
        version: Int,
        comment: Int,
        keepCommentSort: Bool
    ) -> Bool {
        // Only restore positive widths; 0 usually means "unset / auto".
        func widthLine(_ column: String, _ width: Int) -> String {
            guard width > 0 else { return "" }
            return """
                    try
                        set width of column id \(column) of o to \(width)
                    end try
            """
        }
        let sortTail = keepCommentSort ? """
                    try
                        set commentCol to column id comment column of o
                        set visible of commentCol to true
                        set sort column of o to commentCol
                        set sort direction of commentCol to normal
                    end try
        """ : ""
        let script = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return "skip"
            set frontW to front Finder window
            set current view of frontW to list view
            set o to list view options of frontW
        \(widthLine("name column", name))
        \(widthLine("modification date column", modificationDate))
        \(widthLine("creation date column", creationDate))
        \(widthLine("size column", size))
        \(widthLine("kind column", kind))
        \(widthLine("label column", label))
        \(widthLine("version column", version))
        \(widthLine("comment column", comment > 0 ? comment : 90))
        \(sortTail)
            return "ok"
        end tell
        """
        let result = runShellScript("osascript <<'APPLESCRIPT'\n\(script)\nAPPLESCRIPT\n")
        AppLogger.shared.log("Ext restoreColumnWidths exit=\(result.exitCode) out=\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return result.exitCode == 0
    }

    private func copyFinderPathsToPasteboard() {
        var paths = selectedFinderItemURLs().map { $0.standardizedFileURL.path }
        AppLogger.shared.log("copyFinderPaths selectedCount=\(paths.count)")
        if paths.isEmpty, let currentPath = currentFinderDirectoryURL()?.standardizedFileURL.path {
            paths = [currentPath]
        }
        guard !paths.isEmpty else {
            NSSound.beep()
            showCloseFailure(localized("No Finder path to copy", "没有可复制的 Finder 路径"))
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .semibold)) {
            copyPathButton.image = check
            copyPathButton.contentTintColor = .systemGreen
        }
        showCloseFailure(localized("Copied \(paths.count) path(s)", "复制成功（\(paths.count) 个路径）"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            if let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12.5, weight: .regular)) {
                self.copyPathButton.image = image
            }
            self.copyPathButton.contentTintColor = .labelColor
        }
    }

    private func goToClipboardPath() {
        AppLogger.shared.log("goToClipboardPath")
        guard let path = clipboardPathCandidate() else {
            NSSound.beep()
            showPathMissingAlert(path: nil)
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            AppLogger.shared.log("goToClipboardPath missing path=\(path)")
            NSSound.beep()
            showPathMissingAlert(path: path)
            return
        }

        navigateFinder(to: path, source: "goPth")
    }

    private func showPathMissingAlert(path: String?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("Path does not exist", "地址不存在")
        if let path, !path.isEmpty {
            alert.informativeText = path
        } else {
            alert.informativeText = localized("Clipboard has no valid path.", "剪切板中没有有效路径。")
        }
        alert.addButton(withTitle: localized("OK", "好"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        // Alert steals activation; return focus to Finder so the path bar stays usable.
        refocusAttachedFinderWindow(activateFinder: true)
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate(options: [.activateIgnoringOtherApps])
        }
        updateHotKeyRegistrationForFrontmostApp()
    }

    /// Best-effort path from clipboard: plain text, file:// URL, or Finder file URLs.
    private func clipboardPathCandidate() -> String? {
        let pasteboard = NSPasteboard.general

        if let text = pasteboard.string(forType: .string)?
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            if let fromText = normalizedExistingPathCandidate(text) {
                return fromText
            }
            // Prefer the normalized form even when missing, so callers can report "地址不存在".
            let normalized = normalizePath((text as NSString).expandingTildeInPath)
            if !normalized.isEmpty {
                return normalized
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let first = urls.first {
            return normalizePath(first.standardizedFileURL.path)
        }

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let filenames = pasteboard.propertyList(forType: filenamesType) as? [String],
           let first = filenames.first {
            return normalizePath(first)
        }

        return nil
    }

    private func normalizedExistingPathCandidate(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("file:") {
            if let url = URL(string: text), url.isFileURL {
                return normalizePath(url.path)
            }
            if let url = URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? text),
               url.isFileURL {
                return normalizePath(url.path)
            }
        }

        let expanded = normalizePath((text as NSString).expandingTildeInPath)
        return expanded.isEmpty ? nil : expanded
    }

    private func runShellScript(_ script: String) -> (exitCode: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        return (process.terminationStatus, output, errorOutput)
    }

    private func directoryURLFromPathField() -> URL? {
        let rawPath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        let path = normalizePath(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func renameSelectedFinderItem() {
        unregisterHotKeys()
        runFinderScriptAsync("""
        tell application "Finder" to activate
        tell application "System Events"
            key code 36
        end tell
        """)
        suspendHotKeysUntilFinderRenameEnds()
    }

    private func enterFinderRenameModeWithoutSelectionReset() {
        unregisterHotKeys()
        runFinderScriptAsync("""
        tell application "Finder" to activate
        tell application "System Events"
            key code 36
        end tell
        """)
        suspendHotKeysUntilFinderRenameEnds()
    }

    private func handleEnterKeyForFinder() {
        AppLogger.shared.log("handleEnterKeyForFinder editingPath=\(isEditingPath) renaming=\(isFinderRenamingItem())")
        if isEditingPath {
            openEnteredPath()
            return
        }
        if isFinderRenamingItem() {
            confirmFinderRename()
            return
        }
        performFinderOperation(.open)
    }

    private func confirmFinderRename() {
        unregisterHotKeys()
        isFinderRenameHotKeysSuspended = false
        runFinderScriptAsync("""
        tell application "System Events"
            key code 36
        end tell
        """)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self else { return }
            self.updateHotKeyRegistrationForFrontmostApp()
        }
    }

    private func suspendHotKeysUntilFinderRenameEnds() {
        stopRenameHotKeyResumeTimer()
        isFinderRenameHotKeysSuspended = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if !self.isFinderRenamingItem() {
                    timer.invalidate()
                    self.renameHotKeyResumeTimer = nil
                    self.isFinderRenameHotKeysSuspended = false
                    self.updateHotKeyRegistrationForFrontmostApp()
                }
            }
            self.renameHotKeyResumeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopRenameHotKeyResumeTimer() {
        renameHotKeyResumeTimer?.invalidate()
        renameHotKeyResumeTimer = nil
        isFinderRenameHotKeysSuspended = false
    }

    private func isFinderRenamingItem() -> Bool {
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = AXSafe.element(focusedValue) else {
            return false
        }

        var roleValue: CFTypeRef?
        var subroleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleValue)
        _ = AXUIElementCopyAttributeValue(focusedElement, kAXSubroleAttribute as CFString, &subroleValue)

        let role = roleValue as? String
        let subrole = subroleValue as? String
        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || subrole == "AXInlineTextField"
    }

    private enum FinderOperation {
        case rename
        case open
        case copy
        case cut
        case paste
        case delete
    }

    private func performFinderOperation(_ operation: FinderOperation) {
        AppLogger.shared.log("performFinderOperation \(operation)")
        guard ensureAccessibilityPermission(prompt: true) else {
            AppLogger.shared.log("performFinderOperation blocked: accessibility permission missing operation=\(operation)")
            NSSound.beep()
            showCloseFailure(localized("Accessibility permission is not enabled", "辅助功能权限未生效"))
            return
        }
        suppressAutoHide(duration: 0.8)
        endPathEditing()
        switch operation {
        case .cut, .copy, .paste:
            guard isFinderFrontmost else {
                AppLogger.shared.log("performFinderOperation skipped outside Finder \(operation)")
                return
            }
        default:
            break
        }
        // Freeze panel geometry before activating Finder / sending keys — otherwise
        // the follow timer remasures AX mid-rename and FP drops into the file list.
        if operation == .rename {
            isFinderRenameHotKeysSuspended = true
        }
        refocusAttachedFinderWindow(activateFinder: true)

        let operationDelay: TimeInterval = operation == .rename ? 0.12 : 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + operationDelay) { [weak self] in
            guard let self else { return }
            switch operation {
            case .rename:
                self.renameSelectedFinderItem()
            case .open:
                if self.isFinderRenamingItem() {
                    self.sendFinderKeyStroke(keyCode: 36, using: [], suspendingHotKeys: true)
                } else {
                    self.sendFinderKeyStroke(key: "o", using: ["command down"], suspendingHotKeys: true)
                }
            case .copy:
                self.hasPendingCut = false
                self.pendingCutURLs.removeAll()
                self.sendFinderKeyStroke(key: "c", using: ["command down"], suspendingHotKeys: true)
            case .cut:
                // Real cut = remember selection and move on paste.
                // Do NOT send ⌘C — that makes Finder treat the next paste as a copy
                // ("正在拷贝"), which is what users reported for Cmd+X.
                let urls = self.selectedFinderItemURLs()
                guard !urls.isEmpty else {
                    NSSound.beep()
                    self.showCloseFailure(self.localized("No selection", "未选中文件"))
                    return
                }
                self.hasPendingCut = true
                self.pendingCutURLs = urls
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
                self.showCloseFailure(self.localized("Cut \(urls.count) item(s)", "已剪切 \(urls.count) 项"))
            case .paste:
                if self.hasPendingCut {
                    if self.pendingCutURLs.isEmpty {
                        self.updatePendingCutURLsFromPasteboard()
                    }
                    guard !self.pendingCutURLs.isEmpty else {
                        NSSound.beep()
                        return
                    }
                    self.movePendingCutItemsToCurrentDirectory()
                } else {
                    if !self.copyClipboardItemsToCurrentDirectory() {
                        self.sendFinderKeyStroke(key: "v", using: ["command down"], suspendingHotKeys: true)
                    }
                }
            case .delete:
                self.deleteSelectedFinderItemsToTrash()
            }
        }
    }

    private func sendFinderKeyStroke(key: String, using modifiers: [String], suspendingHotKeys: Bool = false) {
        if suspendingHotKeys {
            unregisterHotKeys()
        }
        let modifierClause = modifiers.isEmpty ? "" : " using {\(modifiers.joined(separator: ", "))}"
        runFinderScriptAsync("""
        tell application "Finder" to activate
        tell application "System Events"
            keystroke "\(escapedAppleScript(key))"\(modifierClause)
        end tell
        """)
        if suspendingHotKeys {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.updateHotKeyRegistrationForFrontmostApp()
            }
        }
    }

    private func sendFinderKeyStroke(keyCode: Int, using modifiers: [String], suspendingHotKeys: Bool = false) {
        if suspendingHotKeys {
            unregisterHotKeys()
        }
        let modifierClause = modifiers.isEmpty ? "" : " using {\(modifiers.joined(separator: ", "))}"
        runFinderScriptAsync("""
        tell application "Finder" to activate
        tell application "System Events"
            key code \(keyCode)\(modifierClause)
        end tell
        """)
        if suspendingHotKeys {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.updateHotKeyRegistrationForFrontmostApp()
            }
        }
    }

    @objc private func showHistoryMenu(_ sender: NSButton) {
        toggleHistoryMenu()
    }

    private func toggleHistoryMenu() {
        guard settingsPanel?.isVisible != true else { return }
        if historyPanel?.isVisible == true {
            hideHistoryPanel()
            return
        }
        suppressAutoHide()
        refreshVisibleHistory()
        showHistoryPanelBelowAddressBar()
    }

    private func refreshVisibleHistory() {
        visibleHistory = Array(history.reversed().reduce(into: [HistoryEntry]()) { result, entry in
            if !result.contains(where: { $0.path == entry.path }) {
                result.append(entry)
            }
        }.prefix(9))
    }

    private func toggleBookmark() {
        showBookmarkEditor()
    }

    private func bookmarkPathCandidate() -> String? {
        let finderPath = currentFinderPath()
        let fallbackPath = normalizePath(pathField.stringValue)
        let path = normalizePath(finderPath?.isEmpty == false ? finderPath! : fallbackPath)
        var isDirectory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return path
    }

    private func showBookmarkEditor(for existingBookmark: Bookmark? = nil) {
        guard let path = existingBookmark?.path ?? bookmarkPathCandidate() else {
            NSSound.beep()
            showCloseFailure(localized("No folder to bookmark", "没有可收藏的文件夹"))
            return
        }

        let existing = existingBookmark ?? bookmarks.first { $0.path == path }
        editingBookmarkID = existing?.id

        let editor = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        editor.title = localized("Edit bookmark", "编辑收藏")
        editor.isReleasedWhenClosed = false
        // The address bar continuously orders itself to the front while it
        // follows Finder. Keep this editor on a higher window level so it
        // remains interactive instead of appearing behind the path bar.
        editor.isFloatingPanel = true
        editor.level = .modalPanel

        let content = NSView()
        let folderField = NSTextField(string: existing?.folder ?? localized("Bookmarks", "收藏夹"))
        let folderPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        folderPicker.addItem(withTitle: localized("Choose existing folder", "选择已有文件夹"))
        let existingFolders = Array(Set(bookmarks.map(\.folder))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        for folder in existingFolders {
            folderPicker.addItem(withTitle: folder)
        }
        folderPicker.selectItem(at: 0)
        folderPicker.isEnabled = !existingFolders.isEmpty
        folderPicker.target = self
        folderPicker.action = #selector(bookmarkFolderPickerChanged(_:))
        let nameField = NSTextField(string: existing?.name ?? URL(fileURLWithPath: path).lastPathComponent)
        let pathField = NSTextField(string: existing?.path ?? path)
        [folderField, folderPicker, nameField, pathField].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let folderLabel = NSTextField(labelWithString: localized("Folder", "放置的文件夹名称"))
        let nameLabel = NSTextField(labelWithString: localized("Name", "收藏的地址名字"))
        let pathLabel = NSTextField(labelWithString: localized("Address", "收藏的地址"))
        [folderLabel, nameLabel, pathLabel].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let cancelButton = NSButton(title: localized("Cancel", "取消"), target: self, action: #selector(cancelBookmarkEditor))
        let saveButton = NSButton(title: localized("Save", "保存"), target: self, action: #selector(saveBookmarkEditor))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor

        let removeButton: NSButton? = existing == nil
            ? nil
            : NSButton(title: localized("Remove bookmark", "取消收藏"), target: self, action: #selector(removeBookmark))
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
        NSApp.activate(ignoringOtherApps: true)
        editor.center()
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
        let path = normalizePath(rawPath)
        var isDirectory: ObjCBool = false
        guard !folder.isEmpty, !name.isEmpty, !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            showCloseFailure(localized("Enter a valid folder bookmark", "请填写有效的文件夹收藏"))
            return
        }

        var updatedBookmarks = bookmarks
        let bookmarkID = editingBookmarkID ?? updatedBookmarks.first(where: { $0.path == path })?.id ?? UUID()
        let bookmark = Bookmark(id: bookmarkID, folder: folder, name: name, path: path)
        if let index = updatedBookmarks.firstIndex(where: { $0.id == bookmarkID }) {
            updatedBookmarks[index] = bookmark
        } else {
            updatedBookmarks.append(bookmark)
        }
        bookmarks = updatedBookmarks
        rebuildBookmarkFolderButtons()
        updateBookmarkButton()
        showCloseFailure(localized("Bookmark saved", "收藏已保存"))
        cancelBookmarkEditor()
    }

    @objc private func removeBookmark() {
        guard let editingBookmarkID else { return }
        bookmarks.removeAll { $0.id == editingBookmarkID }
        rebuildBookmarkFolderButtons()
        updateBookmarkButton()
        showCloseFailure(localized("Bookmark removed", "已取消收藏"))
        cancelBookmarkEditor()
    }

    private func rebuildBookmarkFolderButtons() {
        guard let bookmarkFolderStack else { return }
        for button in bookmarkFolderButtons {
            buttonHandlers.removeValue(forKey: button)
            bookmarkFolderStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        bookmarkFolderButtons.removeAll()

        let folders = orderedBookmarkFolders()
        bookmarksEmptyLabel?.isHidden = !folders.isEmpty
        bookmarkFolderStack.isHidden = folders.isEmpty
        for folder in folders {
            let button = BookmarkFolderButton(title: folder, target: nil, action: nil)
            configureTextToolButton(button)
            button.toolTip = localized("Open bookmark folder", "打开收藏文件夹")
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                // Defer menu popup until after the current mouse event finishes,
                // otherwise the same mouseUp can select a menu item immediately.
                DispatchQueue.main.async { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.showBookmarkFolderMenu(folder, from: button)
                }
            }
            button.onDrag = { [weak self] screenPoint in
                self?.previewBookmarkFolderMove(folder, to: screenPoint)
            }
            button.onDrop = { [weak self] screenPoint in
                self?.commitBookmarkFolderMove(folder, to: screenPoint)
            }
            button.rightMouseDownHandler = { [weak self] in
                self?.showBookmarkFolderEditor(folder)
            }
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            bookmarkFolderStack.addArrangedSubview(button)
            bookmarkFolderButtons.append(button)
        }
    }

    private func orderedBookmarkFolders() -> [String] {
        let allFolders = Array(Set(bookmarks.map(\.folder)))
        let availableFolders = Set(allFolders)
        let storedFolders = bookmarkFolderOrder.filter { availableFolders.contains($0) }
        let newFolders = allFolders
            .filter { !storedFolders.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return storedFolders + newFolders
    }

    private func previewBookmarkFolderMove(_ folder: String, to screenPoint: NSPoint) {
        guard let bookmarkFolderStack else { return }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let stackPoint = bookmarkFolderStack.convert(windowPoint, from: nil)
        let arrangedButtons = bookmarkFolderStack.arrangedSubviews.compactMap { $0 as? BookmarkFolderButton }
        guard let draggedButton = arrangedButtons.first(where: { $0.title == folder }) else { return }
        let remainingButtons = arrangedButtons.filter { $0 !== draggedButton }
        var targetIndex = remainingButtons.count
        for (index, button) in remainingButtons.enumerated() where stackPoint.x < button.frame.midX {
            targetIndex = index
            break
        }

        let currentIndex = arrangedButtons.firstIndex(where: { $0 === draggedButton }) ?? 0
        guard currentIndex != targetIndex else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bookmarkFolderStack.removeArrangedSubview(draggedButton)
            bookmarkFolderStack.insertArrangedSubview(draggedButton, at: targetIndex)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        bookmarkFolderButtons = bookmarkFolderStack.arrangedSubviews.compactMap { $0 as? BookmarkFolderButton }
    }

    private func commitBookmarkFolderMove(_ folder: String, to screenPoint: NSPoint) {
        previewBookmarkFolderMove(folder, to: screenPoint)
        let finalOrder = bookmarkFolderStack.arrangedSubviews.compactMap { ($0 as? BookmarkFolderButton)?.title }
        guard finalOrder.contains(folder) else { return }
        bookmarkFolderOrder = finalOrder
    }

    private func showBookmarkFolderMenu(_ folder: String, from sourceButton: NSButton) {
        let folderBookmarks = bookmarks
            .filter { $0.folder == folder }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !folderBookmarks.isEmpty else { return }

        suppressAutoHide(duration: 2.5)
        let menu = NSMenu(title: folder)
        let itemFont = NSFont.systemFont(ofSize: pathFontSize, weight: .regular)
        let rowWidth = max(
            72,
            ceil((folderBookmarks.map { ($0.name as NSString).size(withAttributes: [.font: itemFont]).width }.max() ?? 0) + 24)
        )
        for bookmark in folderBookmarks {
            let item = NSMenuItem(title: bookmark.name, action: nil, keyEquivalent: "")
            let row = BookmarkMenuRowView(
                title: bookmark.name,
                path: bookmark.path,
                font: itemFont,
                width: rowWidth
            )
            row.onOpen = { [weak self, weak menu] in
                menu?.cancelTracking()
                let bookmarkToOpen = bookmark
                // Defer past menu teardown + any in-flight Finder scripts.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.navigateFinder(to: bookmarkToOpen.path, source: "bookmark-menu")
                }
            }
            row.onEdit = { [weak self, weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.async { self?.showBookmarkEditor(for: bookmark) }
            }
            item.view = row
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sourceButton.bounds.height + 8), in: sourceButton)
    }

    private func showBookmarkFolderEditor(_ folder: String) {
        let editor = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        editor.title = localized("Rename bookmark folder", "重命名收藏夹")
        editor.isReleasedWhenClosed = false
        editor.isFloatingPanel = true
        editor.level = .modalPanel

        let content = NSView()
        let label = NSTextField(labelWithString: localized("Folder name", "收藏夹名称"))
        let field = NSTextField(string: folder)
        let cancelButton = NSButton(title: localized("Cancel", "取消"), target: self, action: #selector(cancelBookmarkFolderEditor))
        let saveButton = NSButton(title: localized("Save", "保存"), target: self, action: #selector(saveBookmarkFolderEditor))
        let removeButton = NSButton(title: localized("Delete folder", "删除收藏夹"), target: self, action: #selector(removeBookmarkFolder))
        [label, field, cancelButton, saveButton, removeButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        label.font = .systemFont(ofSize: 13, weight: .medium)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor
        removeButton.contentTintColor = .systemRed

        content.addSubview(label)
        content.addSubview(field)
        content.addSubview(cancelButton)
        content.addSubview(saveButton)
        content.addSubview(removeButton)
        editor.contentView = content
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            label.widthAnchor.constraint(equalToConstant: 88),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            removeButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
        ])

        bookmarkFolderEditorPanel = editor
        bookmarkFolderNameField = field
        editingBookmarkFolderName = folder
        NSApp.activate(ignoringOtherApps: true)
        editor.center()
        editor.makeKeyAndOrderFront(nil)
        editor.makeFirstResponder(field)
    }

    @objc private func cancelBookmarkFolderEditor() {
        bookmarkFolderEditorPanel?.orderOut(nil)
        bookmarkFolderEditorPanel = nil
        editingBookmarkFolderName = nil
    }

    @objc private func saveBookmarkFolderEditor() {
        guard let oldName = editingBookmarkFolderName else { return }
        let newName = bookmarkFolderNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !newName.isEmpty else {
            NSSound.beep()
            return
        }
        bookmarks = bookmarks.map { bookmark in
            bookmark.folder == oldName
                ? Bookmark(id: bookmark.id, folder: newName, name: bookmark.name, path: bookmark.path)
                : bookmark
        }
        bookmarkFolderOrder = bookmarkFolderOrder.reduce(into: []) { result, folder in
            let renamedFolder = folder == oldName ? newName : folder
            if !result.contains(renamedFolder) {
                result.append(renamedFolder)
            }
        }
        rebuildBookmarkFolderButtons()
        showCloseFailure(localized("Bookmark folder renamed", "收藏夹已重命名"))
        cancelBookmarkFolderEditor()
    }

    @objc private func removeBookmarkFolder() {
        guard let folder = editingBookmarkFolderName else { return }
        let count = bookmarks.filter { $0.folder == folder }.count
        let alert = NSAlert()
        alert.messageText = localized("Delete bookmark folder?", "删除收藏夹？")
        alert.informativeText = localized(
            "This will delete \(count) bookmark(s) in \"\(folder)\".",
            "这将删除“\(folder)”中的 \(count) 个收藏地址。"
        )
        alert.addButton(withTitle: localized("Delete", "删除"))
        alert.addButton(withTitle: localized("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        bookmarks.removeAll { $0.folder == folder }
        bookmarkFolderOrder.removeAll { $0 == folder }
        rebuildBookmarkFolderButtons()
        updateBookmarkButton()
        showCloseFailure(localized("Bookmark folder deleted", "收藏夹已删除"))
        cancelBookmarkFolderEditor()
    }

    private func openBookmark(_ bookmark: Bookmark) {
        navigateFinder(to: bookmark.path, source: "bookmark")
    }

    /// Reliable Finder navigation with retry + Workspace fallback.
    /// AppleScript is often busy right after menu clicks / parent navigation;
    /// failing immediately caused "无法打开 Finder 位置" for bookmarks.
    private func navigateFinder(to rawPath: String, source: String, attempt: Int = 0) {
        if isFileDialogMode {
            navigateFileDialog(to: rawPath, source: source)
            return
        }
        let normalizedPath = normalizePath((rawPath as NSString).expandingTildeInPath)
        guard !normalizedPath.isEmpty else {
            NSSound.beep()
            showCloseFailure(localized("Couldn't open Finder location", "无法打开 Finder 位置"))
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory) else {
            AppLogger.shared.log("navigateFinder missing path=\(normalizedPath) source=\(source)")
            NSSound.beep()
            showCloseFailure(localized("Path no longer exists", "路径不存在"))
            return
        }

        let targetURL: URL
        if isDirectory.boolValue {
            targetURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        } else {
            // Bookmark to a file: reveal/select it in Finder.
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: normalizedPath)])
            let parent = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
            pathField.stringValue = normalizePath(parent)
            updateBookmarkButton()
            recordHistory(normalizePath(parent))
            updatePanelFrame(lightweight: true)
            return
        }

        // Wait out in-flight AppleScript / navigation instead of failing.
        if (isExecutingAppleScript || isNavigatingHistory), attempt < 25 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.navigateFinder(to: normalizedPath, source: source, attempt: attempt + 1)
            }
            return
        }

        suppressAutoHide(duration: 2.5)
        isNavigatingHistory = true
        ignoreNextSyncRecordUntil = Date().addingTimeInterval(0.35)

        let opened = setFinderTargetSync(targetURL) || openFolderViaWorkspace(targetURL)
        if opened {
            applyPathToUI(normalizedPath)
            updateBookmarkButton()
            // Allow history recording after navigation flag clears.
            finishFastFinderNavigation(after: 0.05)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.recordHistory(normalizedPath)
            }
            AppLogger.shared.log("navigateFinder ok path=\(normalizedPath) source=\(source) attempt=\(attempt)")
        } else {
            isNavigatingHistory = false
            AppLogger.shared.log("navigateFinder failed path=\(normalizedPath) source=\(source) attempt=\(attempt) busy=\(isExecutingAppleScript)")
            NSSound.beep()
            showCloseFailure(localized("Couldn't open Finder location", "无法打开 Finder 位置"))
        }
    }

    @discardableResult
    private func openFolderViaWorkspace(_ url: URL) -> Bool {
        let path = normalizePath(url.path)
        // Opens/reveals the folder in Finder without AppleScript.
        let ok = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        if ok {
            AppLogger.shared.log("openFolderViaWorkspace ok path=\(path)")
        } else {
            let opened = NSWorkspace.shared.open(url)
            AppLogger.shared.log("openFolderViaWorkspace fallback open=\(opened) path=\(path)")
            return opened
        }
        return ok
    }

    private func updateBookmarkButton() {
        guard let bookmarkButton else { return }
        let path = normalizePath(pathField?.stringValue ?? "")
        let isBookmarked = bookmarks.contains { $0.path == path }
        let tooltip = isBookmarked
            ? localized("Edit bookmark", "编辑收藏")
            : localized("Add bookmark", "收藏当前地址")
        let imageName = isBookmarked ? "star.fill" : "star"
        let configuration = NSImage.SymbolConfiguration(pointSize: max(12, pathFontSize + 1), weight: .regular)
        bookmarkButton.image = NSImage(systemSymbolName: imageName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(configuration)
        bookmarkButton.image?.isTemplate = true
        bookmarkButton.title = ""
        bookmarkButton.imagePosition = .imageOnly
        bookmarkButton.imageScaling = .scaleProportionallyDown
        bookmarkButton.toolTip = tooltip
    }

    private func showCloseFailure(_ message: String) {
        AppLogger.shared.log("messagePanel \(message)")
        closeFailurePanel?.orderOut(nil)
        closeFailurePanel = makeMessagePanel(message: message)
        guard let closeFailurePanel else { return }

        let maxWidth = min(max(panel.frame.width, 280), 520)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]
        let rect = (message as NSString).boundingRect(
            with: NSSize(width: maxWidth - 24, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let width = min(maxWidth, max(180, ceil(rect.width) + 24))
        let height = max(32, min(88, ceil(rect.height) + 16))
        let x = panel.frame.midX - width / 2
        let y = panel.frame.minY - height - 6
        closeFailurePanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        closeFailurePanel.orderFrontRegardless()
        let hold: TimeInterval = message.count > 40 ? 2.8 : 1.4
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            self?.closeFailurePanel?.orderOut(nil)
            self?.closeFailurePanel = nil
        }
    }

    private func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        guard prompt else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @objc private func closeFinderAndHide() {
        AppLogger.shared.log("closeFinderAndHide start fileDialog=\(isFileDialogMode) attachedID=\(attachedFinderWindowID.map(String.init) ?? "nil")")
        suppressAutoAttachUntil = Date().addingTimeInterval(0.04)
        if !ensureAccessibilityPermission(prompt: true) {
            AppLogger.shared.log("closeFinderAndHide blocked: accessibility permission missing")
            NSSound.beep()
            showCloseFailure(localized("Accessibility permission is not enabled", "辅助功能权限未生效"))
            suppressAutoAttachUntil = nil
            return
        }
        let closeResult = isFileDialogMode
            ? closeAttachedFileDialogWithAccessibility()
            : closeAttachedFinderWindowWithAccessibility()
        if !closeResult.didClose {
            AppLogger.shared.log("closeFinderAndHide failed message=\(closeResult.message)")
            NSSound.beep()
            showCloseFailure(closeResult.message)
            suppressAutoAttachUntil = nil
            return
        }
        attachedFinderWindowID = nil
        AppLogger.shared.log("closeFinderAndHide success")
        hidePanelAutomatically(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.suppressAutoAttachUntil = nil
            self.autoAttachIfNeeded()
        }
    }

    @objc private func closeOtherFinderWindows() {
        closeOtherFinderWindows(attempt: 0)
    }

    private func closeOtherFinderWindows(attempt: Int) {
        AppLogger.shared.log("closeOtherFinderWindows attempt=\(attempt)")
        guard ensureAccessibilityPermission(prompt: attempt == 0) else {
            NSSound.beep()
            showCloseFailure(localized("Accessibility permission is not enabled", "辅助功能权限未生效"))
            return
        }
        suppressAutoHide(duration: 1.5)
        if isExecutingAppleScript, attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.closeOtherFinderWindows(attempt: attempt + 1)
            }
            return
        }
        // Close from the back so window 1 (current/front) stays. Using
        // `whose id is not …` fails on many Finder versions and looks like a no-op.
        let script = """
        tell application "Finder"
            set windowCount to (count of Finder windows)
            if windowCount is 0 then return "none"
            if windowCount is 1 then return "only"
            repeat while (count of Finder windows) > 1
                close Finder window (count of Finder windows)
            end repeat
            return "ok"
        end tell
        """
        let result = runFinderScript(script)?.stringValue
        AppLogger.shared.log("closeOtherFinderWindows scriptResult=\(result ?? "nil")")
        if result == "ok" {
            showCloseFailure(localized("Closed other windows", "已关闭其他窗口"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.refreshPathFromFinder()
                self?.updatePanelFrame(lightweight: true)
            }
            return
        }
        if result == "none" || result == "only" {
            let axClosed = closeOtherFinderWindowsWithAccessibility()
            if axClosed > 0 {
                showCloseFailure(localized("Closed other windows", "已关闭其他窗口"))
                return
            }
            showCloseFailure(localized("No other Finder windows", "没有其他 Finder 窗口"))
            return
        }
        let axClosed = closeOtherFinderWindowsWithAccessibility()
        if axClosed > 0 {
            AppLogger.shared.log("closeOtherFinderWindows axClosed=\(axClosed)")
            showCloseFailure(localized("Closed other windows", "已关闭其他窗口"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.refreshPathFromFinder()
                self?.updatePanelFrame(lightweight: true)
            }
            return
        }
        NSSound.beep()
        showCloseFailure(localized("Couldn't close other windows", "无法关闭其他窗口"))
    }

    private func closeOtherFinderWindowsWithAccessibility() -> Int {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return 0
        }
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return 0
        }
        let keepWindow = attachedFinderWindowElement(for: finder) ?? frontFinderWindowElement(for: finder)
        let keepNumber = keepWindow.flatMap { axWindowNumber($0) }
        var closed = 0
        for window in windows {
            if let keepNumber, axWindowNumber(window) == keepNumber { continue }
            if let keepWindow, CFEqual(window, keepWindow) { continue }
            var subroleValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
            let subrole = subroleValue as? String ?? ""
            if subrole == "AXDialog" || subrole == "AXSystemDialog" || subrole == "AXFloatingWindow" {
                continue
            }
            if pressCloseButton(in: window) {
                closed += 1
            }
        }
        return closed
    }

    @objc private func closeAllFinderWindows() {
        AppLogger.shared.log("closeAllFinderWindows")
        guard ensureAccessibilityPermission(prompt: true) else {
            NSSound.beep()
            showCloseFailure(localized("Accessibility permission is not enabled", "辅助功能权限未生效"))
            return
        }
        suppressAutoAttachUntil = Date().addingTimeInterval(0.35)
        let script = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return "none"
            close every Finder window
            return "ok"
        end tell
        """
        guard let result = runFinderScript(script)?.stringValue else {
            NSSound.beep()
            showCloseFailure(localized("Couldn't close Finder windows", "无法关闭 Finder 窗口"))
            suppressAutoAttachUntil = nil
            return
        }
        attachedFinderWindowID = nil
        lastFinderWindowBounds = nil
        lastMainContentBounds = nil
        hidePanelAutomatically(force: true)
        if result == "none" {
            showCloseFailure(localized("No Finder windows", "没有 Finder 窗口"))
        } else {
            AppLogger.shared.log("closeAllFinderWindows ok")
            showCloseFailure(localized("Closed all Finder windows", "已关闭全部窗口"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.suppressAutoAttachUntil = nil
        }
    }

    @objc private func goToParentDirectory() {
        // A navigation may temporarily run the main event loop while Finder
        // processes its Apple event. Ignore repeated clicks until that
        // navigation has finished, rather than queueing another transition.
        guard !isNavigatingHistory, !isNavigatingFileDialog else {
            AppLogger.shared.log("goToParentDirectory ignored while navigation is in progress")
            return
        }
        let currentPath = (isFileDialogMode ? normalizePath(pathField.stringValue) : nil)
            ?? currentFinderPath()
            ?? directoryURLFromPathField()?.path
            ?? normalizePath(pathField.stringValue)
        AppLogger.shared.log("goToParentDirectory current=\(currentPath) fileDialog=\(isFileDialogMode)")
        suppressAutoHide(duration: 1.5)
        guard !currentPath.isEmpty else {
            NSSound.beep()
            AppLogger.shared.log("goToParentDirectory skipped empty current path")
            return
        }
        let currentURL = URL(fileURLWithPath: currentPath, isDirectory: true).standardizedFileURL
        let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
        guard parentURL.path != currentURL.path,
              FileManager.default.fileExists(atPath: parentURL.path) else {
            NSSound.beep()
            AppLogger.shared.log("goToParentDirectory skipped parent=\(parentURL.path)")
            return
        }
        if isFileDialogMode {
            navigateFileDialogToParent(from: currentURL, to: parentURL)
            return
        }
        let pathToSelect = currentURL
        isNavigatingHistory = true
        ignoreNextSyncRecordUntil = Date().addingTimeInterval(0.25)
        guard setFinderTargetSync(parentURL) else {
            isNavigatingHistory = false
            NSSound.beep()
            AppLogger.shared.log("goToParentDirectory failed parent=\(parentURL.path)")
            return
        }
        pathField.stringValue = parentURL.path
        applyPathToUI(parentURL.path)
        updateBookmarkButton()
        finishFastFinderNavigation(after: 0.04, selecting: pathToSelect)
    }

    @objc private func goBack() {
        AppLogger.shared.log("goBack index=\(historyIndex) count=\(history.count)")
        suppressAutoHide(duration: 1.5)
        guard historyIndex > 0 else {
            NSSound.beep()
            return
        }
        let previousHistoryIndex = historyIndex
        historyIndex -= 1
        navigateToHistoryItem(restoring: previousHistoryIndex)
    }

    @objc private func goForward() {
        AppLogger.shared.log("goForward index=\(historyIndex) count=\(history.count)")
        suppressAutoHide(duration: 1.5)
        guard historyIndex >= 0, historyIndex < history.count - 1 else {
            NSSound.beep()
            return
        }
        let previousHistoryIndex = historyIndex
        historyIndex += 1
        navigateToHistoryItem(restoring: previousHistoryIndex)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField {
            return handleSearchFieldCommand(commandSelector)
        }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            hideAutocompletePanel()
            endPathEditing()
            refocusAttachedFinderWindow(activateFinder: true)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !autocompleteCandidates.isEmpty else { return false }
            autocompleteSelectedIndex = min(autocompleteCandidates.count - 1, autocompleteSelectedIndex + 1)
            autocompleteListView?.select(index: autocompleteSelectedIndex)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !autocompleteCandidates.isEmpty else { return false }
            autocompleteSelectedIndex = max(0, autocompleteSelectedIndex - 1)
            autocompleteListView?.select(index: autocompleteSelectedIndex)
            return true
        case #selector(NSResponder.insertTab(_:)):
            if applySelectedAutocomplete(partial: true) {
                return true
            }
            return false
        case #selector(NSResponder.insertNewline(_:)):
            if autocompletePanel?.isVisible == true, applySelectedAutocomplete(partial: false) {
                hideAutocompletePanel()
                openEnteredPath()
                return true
            }
            return false
        default:
            return false
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if obj.object as AnyObject? === searchField {
            isEditingSearch = true
            hideAutocompletePanel()
            return
        }
        guard obj.object as AnyObject? === pathField else { return }
        isEditingPath = true
        // Do not show autocomplete on mere focus/click.
        hideAutocompletePanel()
        hideSearchPanel()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            if field === settingsBackgroundColorField {
                commitSettingsBackgroundColor(from: field)
                return
            }
            if field === settingsDropdownColorField {
                commitSettingsDropdownColor(from: field)
                return
            }
            if field === searchField {
                // Do not auto-collapse here: focusing the field after a toolbar
                // click often ends editing once during panel key-focus setup.
                // Collapse only via Esc / magnifier toggle / opening a result.
                isEditingSearch = false
                return
            }
        }
        if isEditingPath {
            isEditingPath = false
        }
        hideAutocompletePanel()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            if field === settingsBackgroundColorField {
                if parsedHexColorString(field.stringValue) != nil {
                    commitSettingsBackgroundColor(from: field)
                }
                return
            }
            if field === settingsDropdownColorField {
                if parsedHexColorString(field.stringValue) != nil {
                    commitSettingsDropdownColor(from: field)
                }
                return
            }
            if field === searchField {
                updateFolderSearchResults()
                return
            }
        }
        guard isEditingPath else { return }
        // Only after the user actually types/deletes.
        updatePathAutocomplete()
    }

    private func beginPathEditing() {
        guard !isEditingPath else { return }
        guard let panel = panel as? AddressBarPanel else { return }
        suppressAutoHide(duration: 2.5)
        endFolderSearch(collapse: true)
        hideAutocompletePanel()
        enablePanelEditingMode()
        panel.allowsKeyFocus = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        pathField.isHidden = false
        breadcrumbScrollView?.isHidden = true
        panel.makeFirstResponder(pathField)
        pathField.selectText(nil)
        isEditingPath = true
        // Autocomplete stays hidden until the user types.
    }

    private func endPathEditing() {
        isEditingPath = false
        hideAutocompletePanel()
        if let editor = pathField.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        panel.makeFirstResponder(nil)
        pathField.window?.endEditing(for: pathField)
        (panel as? AddressBarPanel)?.allowsKeyFocus = false
        disablePanelEditingMode()
        pathField.needsDisplay = true
        updatePathChromeVisibility()
    }

    private func updatePathChromeVisibility() {
        // Always use the classic editable path field.
        pathField.isHidden = false
        breadcrumbScrollView?.isHidden = true
    }

    private func applyPathToUI(_ path: String) {
        let normalized = normalizePath(path)
        cachedFinderPath = normalized
        if !isEditingPath {
            pathField.stringValue = normalized
        }
        updatePathChromeVisibility()
    }

    private func updatePathAutocomplete() {
        guard isEditingPath else {
            hideAutocompletePanel()
            return
        }
        let input = pathField.stringValue
        let candidates = pathAutocompleteCandidates(for: input)
        autocompleteCandidates = candidates
        autocompleteSelectedIndex = 0
        guard !candidates.isEmpty else {
            hideAutocompletePanel()
            return
        }
        showAutocompletePanel(candidates)
    }

    private func pathAutocompleteCandidates(for input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let hasTrailingSlash = trimmed.hasSuffix("/") || expanded.hasSuffix("/")
        let baseURL = URL(fileURLWithPath: expanded)
        let directoryURL: URL
        let prefix: String
        if hasTrailingSlash {
            directoryURL = baseURL
            prefix = ""
        } else {
            directoryURL = baseURL.deletingLastPathComponent()
            prefix = baseURL.lastPathComponent
        }

        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let prefixLower = prefix.lowercased()
        var matches: [String] = []
        for item in items {
            let name = item.lastPathComponent
            if !prefix.isEmpty, !name.lowercased().hasPrefix(prefixLower) {
                continue
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            let path = isDirectory ? item.path + "/" : item.path
            matches.append(path)
        }
        return Array(matches.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.prefix(300))
    }

    @discardableResult
    private func applySelectedAutocomplete(partial: Bool) -> Bool {
        guard autocompleteCandidates.indices.contains(autocompleteSelectedIndex) else { return false }
        var selected = autocompleteCandidates[autocompleteSelectedIndex]
        if partial {
            // Complete to the selected candidate (folder keeps trailing slash).
        } else if selected.hasSuffix("/") {
            selected = String(selected.dropLast())
        }
        // Prefer showing ~ for home paths while editing.
        let display: String
        let home = NSHomeDirectory()
        if selected == home || selected == home + "/" {
            display = selected.hasSuffix("/") ? "~/" : "~"
        } else if selected.hasPrefix(home + "/") {
            display = "~" + selected.dropFirst(home.count)
        } else {
            display = selected
        }
        pathField.stringValue = display
        if let editor = pathField.currentEditor() {
            editor.selectedRange = NSRange(location: display.count, length: 0)
        }
        updatePathAutocomplete()
        return true
    }

    private func showAutocompletePanel(_ candidates: [String]) {
        if autocompletePanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let list = AutocompleteListView(frame: .zero)
            list.onSelect = { [weak self] path in
                self?.pathField.stringValue = path.hasSuffix("/") ? String(path.dropLast()) : path
                self?.hideAutocompletePanel()
                self?.openEnteredPath()
            }
            panel.contentView = list
            autocompleteListView = list
            autocompletePanel = panel
        }
        let home = NSHomeDirectory()
        let displayRows = candidates.map { path -> String in
            if path.hasPrefix(home + "/") {
                return "~" + path.dropFirst(home.count)
            }
            if path == home || path == home + "/" {
                return path.hasSuffix("/") ? "~/" : "~"
            }
            return path
        }
        let rowHeight: CGFloat = 24
        // Cap visible height; list scrolls when there are many entries.
        let height = min(max(rowHeight, CGFloat(candidates.count) * rowHeight), 320)
        let bar = self.panel!
        let width = max(280, bar.frame.width - 14)
        // Place below the entire FinderPathBar (both rows), not under the path field alone.
        let x = bar.frame.minX + 7
        let y = bar.frame.minY - height - 4
        autocompletePanel?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        autocompleteListView?.configure(
            rows: displayRows,
            selectedIndex: autocompleteSelectedIndex,
            fontSize: pathFontSize,
            backgroundColor: NSColor(hex: dropdownBackgroundColorHex)
        )
        autocompleteListView?.select(index: autocompleteSelectedIndex)
        autocompletePanel?.orderFrontRegardless()
    }

    private func hideAutocompletePanel() {
        autocompletePanel?.orderOut(nil)
        autocompleteCandidates = []
        autocompleteSelectedIndex = 0
    }

    private func updateSearchButtonAppearance() {
        guard let searchButton else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: max(12, pathFontSize + 1), weight: .regular)
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: searchButton.toolTip)?
            .withSymbolConfiguration(configuration)
        searchButton.image?.isTemplate = true
        searchButton.title = ""
        searchButton.imagePosition = .imageOnly
        searchButton.imageScaling = .scaleProportionallyDown
    }

    private func toggleFolderSearch() {
        if isSearchExpanded {
            endFolderSearch(collapse: true)
            refocusAttachedFinderWindow(activateFinder: true)
        } else {
            focusFolderSearch()
        }
    }

    private func focusFolderSearch() {
        manuallyHidden = false
        if !panel.isVisible {
            presentPanel(focusAddressBar: false, createFinderWindow: false)
        }
        if isEditingPath {
            endPathEditing()
        }
        hideAutocompletePanel()
        hideSearchPanel()

        guard let addressPanel = panel as? AddressBarPanel else { return }
        expandFolderSearch()
        enablePanelEditingMode()
        addressPanel.allowsKeyFocus = true
        isEditingSearch = true
        // Short suppress only — Finder / outside clicks should still dismiss search.

        // Defer key focus until after layout + mouse-up settle; otherwise the
        // first responder briefly attaches and controlTextDidEndEditing runs.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSearchExpanded else { return }
            self.enablePanelEditingMode()
            addressPanel.allowsKeyFocus = true
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            if self.panel.makeFirstResponder(self.searchField) {
                self.searchField.selectText(nil)
                self.isEditingSearch = true
            }
        }
    }

    private func expandFolderSearch() {
        isSearchExpanded = true
        searchField.isHidden = false
        searchField.alphaValue = 1
        searchFieldWidthConstraint.constant = 150
        panel.contentView?.layoutSubtreeIfNeeded()
        updatePanelFrame(lightweight: true)
    }

    private func endFolderSearch(collapse: Bool, updateLayout: Bool = true) {
        searchUpdateWorkItem?.cancel()
        searchUpdateWorkItem = nil
        isEditingSearch = false
        hideSearchPanel()
        if collapse {
            isSearchExpanded = false
            searchField.stringValue = ""
            searchField.isHidden = true
            searchFieldWidthConstraint.constant = 0
            panel.contentView?.layoutSubtreeIfNeeded()
            // Never layout/orderFront while detaching — that re-entered hide and
            // overflowed the stack when Excel/WPS became frontmost.
            if updateLayout, !isHidingOrDetachingPanel, shouldUseFinderWindowContext {
                updatePanelFrame(lightweight: true)
            }
            disablePanelEditingMode(orderFront: updateLayout && !isHidingOrDetachingPanel && panel.isVisible && shouldUseFinderWindowContext)
        }
        if searchField.currentEditor() != nil {
            panel.makeFirstResponder(nil)
            searchField.window?.endEditing(for: searchField)
        }
    }

    private func handleSearchFieldCommand(_ commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            endFolderSearch(collapse: true)
            refocusAttachedFinderWindow(activateFinder: true)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !searchCandidates.isEmpty else { return false }
            searchSelectedIndex = min(searchCandidates.count - 1, searchSelectedIndex + 1)
            searchListView?.select(index: searchSelectedIndex)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !searchCandidates.isEmpty else { return false }
            if searchSelectedIndex < 0 {
                searchSelectedIndex = searchCandidates.count - 1
            } else {
                searchSelectedIndex = max(0, searchSelectedIndex - 1)
            }
            searchListView?.select(index: searchSelectedIndex)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if applySelectedSearchResult() {
                return true
            }
            return true
        default:
            return false
        }
    }

    private func updateFolderSearchResults() {
        searchUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performFolderSearchUpdate()
        }
        searchUpdateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func performFolderSearchUpdate() {
        guard isSearchExpanded else {
            hideSearchPanel()
            return
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            hideSearchPanel()
            return
        }
        let candidates = folderSearchCandidates(query: query)
        searchCandidates = candidates
        searchSelectedIndex = -1
        guard !candidates.isEmpty else {
            hideSearchPanel()
            return
        }
        showSearchPanel(candidates)
    }

    private func folderSearchCandidates(query: String) -> [URL] {
        let keywords = searchKeywords(from: query)
        guard !keywords.isEmpty else { return [] }

        let folderPath = normalizePath(pathField.stringValue.isEmpty ? (currentFinderPath() ?? "") : pathField.stringValue)
        guard !folderPath.isEmpty else { return [] }
        let rootURL = URL(fileURLWithPath: folderPath, isDirectory: true).standardizedFileURL
        searchRootPath = rootURL.path
        let rootPrefix = searchRootPath.hasSuffix("/") ? searchRootPath : searchRootPath + "/"

        // BFS so top-level folders like NHANES are seen before deep trees
        // (FileManager.enumerator is depth-first and can hit the scan cap first).
        var queue: [URL] = [rootURL]
        var matched: [URL] = []
        var totalMatches = 0
        var scanned = 0
        let maxScan = 25_000
        let maxResults = 120
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]

        while !queue.isEmpty, scanned < maxScan {
            let directory = queue.removeFirst()
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children {
                scanned += 1
                if scanned > maxScan { break }

                let itemURL = child.standardizedFileURL
                let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys))
                if values?.isPackage == true {
                    continue
                }

                let relative: String
                if itemURL.path.hasPrefix(rootPrefix) {
                    relative = String(itemURL.path.dropFirst(rootPrefix.count))
                } else {
                    relative = itemURL.lastPathComponent
                }

                if searchPathMatches(relativePath: relative, keywords: keywords) {
                    totalMatches += 1
                    if matched.count < maxResults {
                        matched.append(itemURL)
                    }
                }

                if values?.isDirectory == true {
                    queue.append(itemURL)
                }
            }
        }
        searchTotalMatchCount = totalMatches

        let primary = keywords[0]
        return matched.sorted { lhs, rhs in
            let lRel = searchResultDisplayName(for: lhs)
            let rRel = searchResultDisplayName(for: rhs)
            let lDepth = lRel.split(separator: "/").count
            let rDepth = rRel.split(separator: "/").count
            if lDepth != rDepth { return lDepth < rDepth }
            let ln = lhs.lastPathComponent
            let rn = rhs.lastPathComponent
            let lPrefix = ln.range(of: primary, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil
            let rPrefix = rn.range(of: primary, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil
            if lPrefix != rPrefix { return lPrefix && !rPrefix }
            return lRel.localizedCaseInsensitiveCompare(rRel) == .orderedAscending
        }
    }

    /// Space-separated keywords; preserved as typed (matching is case-insensitive).
    private func searchKeywords(from query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// AND match: each keyword must appear in the relative path (folder names and/or filename).
    private func searchPathMatches(relativePath: String, keywords: [String]) -> Bool {
        guard !relativePath.isEmpty else { return false }
        // localizedStandardContains is case- and diacritic-insensitive.
        return keywords.allSatisfy { relativePath.localizedStandardContains($0) }
    }

    private func searchResultDisplayName(for url: URL) -> String {
        let root = searchRootPath.hasSuffix("/") ? searchRootPath : searchRootPath + "/"
        let path = url.path
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count))
        }
        if path == searchRootPath {
            return url.lastPathComponent
        }
        return url.lastPathComponent
    }

    @discardableResult
    private func applySelectedSearchResult() -> Bool {
        guard searchCandidates.indices.contains(searchSelectedIndex) else { return false }
        openSearchResult(searchCandidates[searchSelectedIndex])
        return true
    }

    private func openSearchResult(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        endFolderSearch(collapse: true)
        if isDirectory.boolValue {
            navigateFinder(to: url.path, source: "folder-search")
        } else {
            selectFinderItem(url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        refocusAttachedFinderWindow(activateFinder: true)
    }

    private func showSearchPanel(_ candidates: [URL]) {
        if searchPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let list = AutocompleteListView(frame: .zero)
            list.onSelect = { [weak self] display in
                guard let self,
                      let match = self.searchCandidates.first(where: {
                          self.searchResultDisplayName(for: $0) == display
                      }) else {
                    return
                }
                self.openSearchResult(match)
            }
            panel.contentView = list
            searchListView = list
            searchPanel = panel
        }
        let displayRows = candidates.map { searchResultDisplayName(for: $0) }
        let rowHeight: CGFloat = 20
        let statusHeight: CGFloat = 18
        let listHeight = min(max(rowHeight, CGFloat(candidates.count) * rowHeight), 280)
        let height = listHeight + statusHeight
        let bar = self.panel!
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(bar.frame) }) ?? NSScreen.main
        let desktopWidth = screen?.visibleFrame.width ?? bar.frame.width
        let font = NSFont.monospacedSystemFont(ofSize: pathFontSize, weight: .regular)
        let textAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let longestTextWidth = displayRows
            .map { ceil(($0 as NSString).size(withAttributes: textAttributes).width) }
            .max() ?? 0
        // Text + side padding + scrollbar gutter; grow with content, cap at desktop width.
        let contentWidth = longestTextWidth + 36
        let minWidth: CGFloat = 280
        let width = min(desktopWidth, max(minWidth, contentWidth))
        let screenFrame = screen?.visibleFrame ?? bar.frame
        var x = bar.frame.maxX - width - 7
        if x < screenFrame.minX + 4 {
            x = screenFrame.minX + 4
        }
        if x + width > screenFrame.maxX - 4 {
            x = max(screenFrame.minX + 4, screenFrame.maxX - 4 - width)
        }
        let y = bar.frame.minY - height - 4
        let statusText: String
        if searchTotalMatchCount > candidates.count {
            statusText = localized(
                "Showing \(candidates.count) of \(searchTotalMatchCount)",
                "显示 \(candidates.count) / 共 \(searchTotalMatchCount) 条"
            )
        } else {
            statusText = localized(
                "\(searchTotalMatchCount) result(s)",
                "共 \(searchTotalMatchCount) 条"
            )
        }
        searchPanel?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        let highlightQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchListView?.configure(
            rows: displayRows,
            selectedIndex: searchSelectedIndex,
            fontSize: pathFontSize,
            backgroundColor: NSColor(hex: dropdownBackgroundColorHex),
            statusText: statusText,
            highlightQuery: highlightQuery
        )
        searchListView?.select(index: searchSelectedIndex)
        searchPanel?.orderFrontRegardless()
    }

    private func hideSearchPanel() {
        searchPanel?.orderOut(nil)
        searchCandidates = []
        searchSelectedIndex = -1
    }

    private func enablePanelEditingMode() {
        if panel.styleMask.contains(.nonactivatingPanel) {
            panel.styleMask.remove(.nonactivatingPanel)
        }
        panel.orderFrontRegardless()
    }

    private func disablePanelEditingMode(orderFront: Bool = true) {
        if !panel.styleMask.contains(.nonactivatingPanel) {
            panel.styleMask.insert(.nonactivatingPanel)
        }
        (panel as? AddressBarPanel)?.allowsKeyFocus = false
        if orderFront, !isHidingOrDetachingPanel {
            panel.orderFrontRegardless()
        }
    }

    private func startFollowingFinder() {
        followTimer?.invalidate()
        // Prefer lower AppleScript pressure; CG/AX handles most window following.
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.syncWithFinder()
        }
        followTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFollowingFinder() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func startAutoAttachFinder() {
        autoAttachTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.autoAttachIfNeeded()
        }
        autoAttachTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAutoAttachFinder() {
        autoAttachTimer?.invalidate()
        autoAttachTimer = nil
    }

    private func autoAttachIfNeeded() {
        if let suppressAutoAttachUntil, Date() < suppressAutoAttachUntil {
            return
        }
        suppressAutoAttachUntil = nil
        guard !isAutoHideSuppressed else { return }

        // Finder in front always wins over a leftover Open/Save dialog attachment.
        if isFinderFrontmost {
            if isFileDialogMode {
                leaveFileDialogModeForFinder()
            }
        } else if let dialog = findFrontFileDialog() {
            enterFileDialogMode(dialog)
            return
        } else if isFileDialogMode {
            clearFileDialogMode()
            if panel.isVisible {
                hidePanelAutomatically()
            }
            return
        }

        guard shouldUseFinderWindowContext else {
            if !hotKeyRefs.isEmpty {
                unregisterHotKeys()
            }
            stopKeyEventTap()
            if panel.isVisible {
                hidePanelAutomatically()
            }
            return
        }
        guard frontFinderWindowBounds() != nil else {
            if shouldKeepPanelVisibleWhileFinderWindowChanges() { return }
            finderWindowUnavailableSince = nil
            lastMainContentBounds = nil
            lastMainContentWindowID = nil
            pendingCollapsedSidebarContent = nil
            if panel.isVisible {
                hidePanelAutomatically()
            }
            return
        }
        finderWindowUnavailableSince = nil
        guard !manuallyHidden else { return }

        if shouldHidePathBarForFinderDialog() {
            hidePathBarForFinderUtilityDialog()
            return
        }
        if hiddenForFinderUtilityDialog {
            hiddenForFinderUtilityDialog = false
        }

        if panel.isVisible {
            syncWithFinder()
        } else {
            AppLogger.shared.log("autoAttach presentPanel")
            presentPanel(focusAddressBar: false, createFinderWindow: false)
        }
        updatePanelLevelForCurrentApp()
    }

    private var isAutoHideSuppressed: Bool {
        if historyPanel?.isVisible == true {
            return true
        }
        if settingsPanel?.isVisible == true {
            return true
        }
        if let suppressAutoHideUntil, Date() < suppressAutoHideUntil {
            return true
        }
        suppressAutoHideUntil = nil
        return false
    }

    private func suppressAutoHide(duration: TimeInterval = 0.8) {
        let until = Date().addingTimeInterval(duration)
        if let suppressAutoHideUntil, suppressAutoHideUntil > until {
            return
        }
        suppressAutoHideUntil = until
    }

    private func beginFinderWindowTransition() {
        // Finder can briefly report no usable window while it creates a new
        // window or changes a window's target. Keep the existing bar visible
        // through that short transition instead of hiding and reattaching it.
        suppressAutoHide(duration: 0.8)
        finderWindowUnavailableSince = nil
    }

    private func shouldKeepPanelVisibleWhileFinderWindowChanges() -> Bool {
        if isNavigatingHistory || isEditingPath || isAutoHideSuppressed {
            return true
        }
        let now = Date()
        if finderWindowUnavailableSince == nil {
            finderWindowUnavailableSince = now
        }
        guard let finderWindowUnavailableSince else { return false }
        return now.timeIntervalSince(finderWindowUnavailableSince) < 1.2
    }

    private func startMouseMonitor() {
        stopMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            guard self.panel.isVisible else { return event }

            switch event.type {
            case .leftMouseDown:
                if event.window === self.panel {
                    self.dismissFolderSearchIfClickOutsideSearchUI(atWindowPoint: event.locationInWindow)
                    self.closeHistoryIfClickIsInPanelOutsideHistoryButton(at: event.locationInWindow)
                } else {
                    self.dismissFolderSearchIfClickOutsideSearchUI(atScreenPoint: NSEvent.mouseLocation)
                    self.closeHistoryIfClickIsOutsidePanels(at: NSEvent.mouseLocation)
                }
                self.closeToolbarMenuIfClickIsOutsidePanels(at: NSEvent.mouseLocation)
                if event.window === self.panel, self.dispatchButtonClick(at: event.locationInWindow) {
                    return nil
                }
                if event.clickCount == 2 {
                    if let index = self.characterIndexUnderMouseInPathField() {
                        self.openPathComponent(at: index)
                        return nil
                    }
                }
                guard event.window === self.panel else { return event }
                self.beginLongPressCandidate(with: event)
            case .leftMouseDragged:
                guard event.window === self.panel else { return event }
                if self.isDraggingPanel {
                    self.dragPanel(with: event)
                    return nil
                }
            case .leftMouseUp:
                guard event.window === self.panel else { return event }
                if self.suppressNextToolbarMouseUp {
                    self.suppressNextToolbarMouseUp = false
                    self.endLongPressOrDrag()
                    return nil
                }
                let wasDragging = self.isDraggingPanel
                self.endLongPressOrDrag()
                if wasDragging {
                    return nil
                }
            default:
                break
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                // Never touch Finder/AppleScript while another app is frontmost.
                // Historical crashes: mouse → bounds/path AppleScript → runloop reentry → SIGTRAP/SIGSEGV.
                guard self.shouldUseFinderWindowContext || self.panel.isVisible else { return }
                switch event.type {
                case .leftMouseDown:
                    self.handleGlobalMouseDown(at: NSEvent.mouseLocation)
                case .leftMouseUp:
                    self.handleGlobalMouseUp()
                case .leftMouseDragged:
                    if self.isFreezingDuringFinderMouseDrag
                        || self.isLiveTrackingFinderGeometry
                        || self.panel.isVisible {
                        self.updatePanelFrame(lightweight: true)
                    }
                default:
                    break
                }
            }
        }
        // Do NOT install a CGEvent mouse tap. It races with NSAppleScript's
        // nested run-loop and has produced fatal dispatch_sync / SIGSEGV crashes
        // when switching to VS Code / other apps. NSEvent monitors are enough.
        stopMouseEventTap()
    }

    private func startMouseEventTap() {
        stopMouseEventTap()
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<FinderPathApp>.fromOpaque(refcon).takeUnretainedValue()
                // Must handle disable notifications before touching event fields.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = app.mouseEventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged else {
                    return Unmanaged.passUnretained(event)
                }
                let location = app.appKitScreenPoint(fromQuartzPoint: event.location)
                DispatchQueue.main.async {
                    guard app.panel.isVisible
                            || app.isFreezingDuringFinderMouseDrag
                            || app.isLiveTrackingFinderGeometry
                            || app.isSearchExpanded
                            || app.isEditingPath else {
                        return
                    }
                    if type == .leftMouseDown {
                        app.handleGlobalMouseDown(at: location)
                    } else if type == .leftMouseUp {
                        app.handleGlobalMouseUp()
                    } else if type == .leftMouseDragged {
                        if app.isFreezingDuringFinderMouseDrag
                            || app.isLiveTrackingFinderGeometry
                            || app.panel.isVisible {
                            app.updatePanelFrame(lightweight: true)
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return
        }
        mouseEventTap = tap
        mouseEventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let mouseEventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), mouseEventTapRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startKeyEventTap() {
        // Only tap while Finder is frontmost and the path bar is visible.
        // Avoid leaving a system-wide key tap armed when switching to other apps.
        guard isFinderFrontmost, panel.isVisible, settingsPanel?.isVisible != true else {
            finderKeyTapArmed = false
            stopKeyEventTap()
            return
        }
        finderKeyTapArmed = true
        if keyEventTap != nil { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let app = Unmanaged<FinderPathApp>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = app.keyEventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard let refcon, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }
                let app = Unmanaged<FinderPathApp>.fromOpaque(refcon).takeUnretainedValue()
                if app.shouldInterceptReturnKey(event) {
                    DispatchQueue.main.async {
                        app.handleEnterKeyForFinder()
                    }
                    return nil
                }
                if let operation = app.finderClipboardOperation(for: event) {
                    DispatchQueue.main.async {
                        app.performFinderOperation(operation)
                    }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            finderKeyTapArmed = false
            AppLogger.shared.log("startKeyEventTap failed — Return interception unavailable")
            return
        }
        keyEventTap = tap
        keyEventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let keyEventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), keyEventTapRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.shared.log("keyEventTap started for Return and clipboard")
    }

    private func stopKeyEventTap() {
        finderKeyTapArmed = false
        if let keyEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyEventTapRunLoopSource, .commonModes)
            self.keyEventTapRunLoopSource = nil
        }
        if let keyEventTap {
            CGEvent.tapEnable(tap: keyEventTap, enable: false)
            self.keyEventTap = nil
            AppLogger.shared.log("keyEventTap stopped")
        }
    }

    private func shouldInterceptReturnKey(_ event: CGEvent) -> Bool {
        guard finderKeyTapArmed,
              panel.isVisible,
              !isEditingPath,
              !isEditingSearch,
              !isFinderRenameHotKeysSuspended,
              settingsPanel?.isVisible != true,
              donationPanel?.isVisible != true else {
            return false
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) else {
            return false
        }
        let flags = event.flags
        guard !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else {
            return false
        }
        return true
    }

    /// Finder-only clipboard keys. ⌘V is swallowed only for pending cut (move-on-paste).
    /// Ordinary copy/paste of files must pass through, or the first ⌘V in the next
    /// app after leaving Finder is eaten.
    private func finderClipboardOperation(for event: CGEvent) -> FinderOperation? {
        guard finderKeyTapArmed,
              panel.isVisible,
              !isEditingPath,
              !isEditingSearch,
              !isFinderRenameHotKeysSuspended,
              settingsPanel?.isVisible != true,
              donationPanel?.isVisible != true else {
            return nil
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        guard !flags.contains(.maskShift), !flags.contains(.maskAlternate) else { return nil }

        if keyCode == Int64(kVK_ANSI_C), command, !control {
            if hasPendingCut {
                DispatchQueue.main.async { [weak self] in
                    self?.hasPendingCut = false
                    self?.pendingCutURLs.removeAll()
                }
            }
            return nil
        }
        if keyCode == Int64(kVK_ANSI_X), command || control {
            return .cut
        }
        if keyCode == Int64(kVK_ANSI_V), command || control, hasPendingCut {
            return .paste
        }
        return nil
    }

    private func dispatchButtonClick(at windowPoint: NSPoint) -> Bool {
        // Prefer hit-testing arranged toolbar controls (including Ext) with a
        // slightly expanded hit box so narrow text buttons are easier to click.
        guard shouldDispatchButtonClick() else { return false }

        let candidates = iconButtons + secondToolbarButtons
        for button in candidates where !button.isHidden && button.isEnabled {
            let pointInButton = button.convert(windowPoint, from: nil)
            let hitBounds = button.bounds.insetBy(dx: -3, dy: -4)
            guard hitBounds.contains(pointInButton), let handler = buttonHandlers[button] else { continue }

            lastButtonDispatchAt = Date()
            suppressNextToolbarMouseUp = true
            if button === searchButton {
                DispatchQueue.main.async { [weak self] in
                    handler()
                    self?.suppressNextToolbarMouseUp = false
                }
                return true
            }
            endFolderSearch(collapse: true)
            endPathEditing()
            if button !== extensionButton {
                disablePanelEditingMode()
            }
            DispatchQueue.main.async { [weak self] in
                handler()
                self?.suppressNextToolbarMouseUp = false
            }
            return true
        }
        return false
    }

    private func dispatchButtonClick(atScreenPoint screenPoint: NSPoint) {
        guard panel.isVisible, panel.frame.contains(screenPoint), shouldDispatchButtonClick() else { return }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        _ = dispatchButtonClick(at: windowPoint)
    }

    private func handleGlobalMouseDown(at screenPoint: NSPoint) {
        // Ignore clicks while another app owns the focus — queued mouse events
        // from the moment of switching into Excel/WPS must not touch Finder/AX.
        guard shouldUseFinderWindowContext || (panel.isVisible && panel.frame.contains(screenPoint)) else {
            return
        }

        let now = Date()
        let distance = hypot(screenPoint.x - lastGlobalMouseDownPoint.x, screenPoint.y - lastGlobalMouseDownPoint.y)
        if now.timeIntervalSince(lastGlobalMouseDownAt) < 0.05 && distance < 2 {
            return
        }
        lastGlobalMouseDownAt = now
        lastGlobalMouseDownPoint = screenPoint

        if let searchPanel, searchPanel.isVisible, searchPanel.frame.contains(screenPoint) {
            return
        }

        if panel.isVisible, panel.frame.contains(screenPoint) {
            let windowPoint = panel.convertPoint(fromScreen: screenPoint)
            dismissFolderSearchIfClickOutsideSearchUI(atWindowPoint: windowPoint)
            closeHistoryIfClickIsInPanelOutsideHistoryButton(at: windowPoint)
            // Global/tap path must also dispatch toolbar buttons (Ext etc.);
            // otherwise clicks can look dead when the local monitor misses them.
            if dispatchButtonClick(at: windowPoint) {
                return
            }
            if isPointInsidePathField(windowPoint) {
                beginPathEditing()
            }
            return
        }

        guard shouldUseFinderWindowContext else { return }

        if isSearchExpanded {
            endFolderSearch(collapse: true)
        }
        if isEditingPath {
            endPathEditing()
            updatePanelFrame(lightweight: true)
        }
        hideAutocompletePanel()
        closeHistoryIfClickIsOutsidePanels(at: screenPoint)
        closeToolbarMenuIfClickIsOutsidePanels(at: screenPoint)
        beginFreezingIfMouseDownInsideFinder(at: screenPoint)
    }

    private func dismissFolderSearchIfClickOutsideSearchUI(atWindowPoint windowPoint: NSPoint) {
        guard isSearchExpanded else { return }
        if isPoint(windowPoint, inside: searchField) || isPoint(windowPoint, inside: searchButton) {
            return
        }
        endFolderSearch(collapse: true)
    }

    private func dismissFolderSearchIfClickOutsideSearchUI(atScreenPoint screenPoint: NSPoint) {
        guard isSearchExpanded else { return }
        if let searchPanel, searchPanel.isVisible, searchPanel.frame.contains(screenPoint) {
            return
        }
        if panel.isVisible, panel.frame.contains(screenPoint) {
            let windowPoint = panel.convertPoint(fromScreen: screenPoint)
            dismissFolderSearchIfClickOutsideSearchUI(atWindowPoint: windowPoint)
            return
        }
        endFolderSearch(collapse: true)
    }

    private func beginFreezingIfMouseDownInsideFinder(at screenPoint: NSPoint) {
        guard panel.isVisible,
              let finderFrame = frontFinderWindowBounds() else {
            isFreezingDuringFinderMouseDrag = false
            isLiveTrackingFinderGeometry = false
            return
        }
        // Include a margin so window-edge resize grips are tracked too.
        let padded = finderFrame.insetBy(dx: -10, dy: -10)
        let nearEdge = isPointNearFrameEdge(screenPoint, frame: finderFrame, threshold: 10)
        isFreezingDuringFinderMouseDrag = padded.contains(screenPoint)
        isLiveTrackingFinderGeometry = isFreezingDuringFinderMouseDrag || nearEdge
    }

    private func isPointNearFrameEdge(_ point: NSPoint, frame: NSRect, threshold: CGFloat) -> Bool {
        let outer = frame.insetBy(dx: -threshold, dy: -threshold)
        let inner = frame.insetBy(dx: threshold, dy: threshold)
        return outer.contains(point) && !inner.contains(point)
    }

    private func handleGlobalMouseUp() {
        let needsFullRefresh = isFreezingDuringFinderMouseDrag || isLiveTrackingFinderGeometry
        isFreezingDuringFinderMouseDrag = false
        isLiveTrackingFinderGeometry = false
        // Full refresh after resize/drag so AX content bounds catch up.
        // Also force a path sync — double-clicking a folder sets the freeze
        // flags and otherwise skips path updates until a stale AX read wins.
        if needsFullRefresh {
            lastPathSyncAt = .distantPast
            if shouldUseFinderWindowContext, !isEditingPath, !isEditingSearch {
                if let path = currentFinderPath(allowAppleScript: true, preferAppleScript: true), !path.isEmpty {
                    if path != normalizePath(pathField.stringValue) {
                        applyPathToUI(path)
                        recordHistory(path)
                    }
                }
            }
        }
        updatePanelFrame(lightweight: !needsFullRefresh)
    }

    private func closeHistoryIfClickIsOutsidePanels(at screenPoint: NSPoint) {
        guard historyPanel?.isVisible == true else { return }
        if panel.frame.contains(screenPoint) || historyPanel?.frame.contains(screenPoint) == true {
            return
        }
        hideHistoryPanel()
    }

    private func closeHistoryIfClickIsInPanelOutsideHistoryButton(at windowPoint: NSPoint) {
        guard historyPanel?.isVisible == true else { return }
        if isPoint(windowPoint, inside: historyButton) {
            return
        }
        hideHistoryPanel()
    }

    private func closeToolbarMenuIfClickIsOutsidePanels(at screenPoint: NSPoint) {
        guard toolbarMenuPanel?.isVisible == true else { return }
        if panel.frame.contains(screenPoint) || toolbarMenuPanel?.frame.contains(screenPoint) == true {
            return
        }
        hideToolbarMenu()
    }

    private func isPoint(_ windowPoint: NSPoint, inside view: NSView?) -> Bool {
        guard let view, !view.isHidden else { return false }
        if let control = view as? NSControl, !control.isEnabled { return false }
        let pointInView = view.convert(windowPoint, from: nil)
        return view.bounds.contains(pointInView)
    }

    private func isPointInsidePathField(_ windowPoint: NSPoint) -> Bool {
        guard !pathField.isHidden else { return false }
        let pointInField = pathField.convert(windowPoint, from: nil)
        return pathField.bounds.contains(pointInField)
    }

    private func shouldDispatchButtonClick() -> Bool {
        if let lastButtonDispatchAt, Date().timeIntervalSince(lastButtonDispatchAt) < 0.08 {
            return false
        }
        return true
    }

    private func appKitScreenPoint(fromQuartzPoint point: CGPoint) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { screen in
            point.x >= screen.frame.minX && point.x <= screen.frame.maxX
        }) ?? NSScreen.main else {
            return NSPoint(x: point.x, y: point.y)
        }
        return NSPoint(x: point.x, y: screen.frame.maxY - point.y)
    }

    private func characterIndexUnderMouseInPathField() -> Int? {
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInField = pathField.convert(windowPoint, from: nil)
        guard pathField.bounds.contains(pointInField) else { return nil }
        return pathField.characterIndex(at: pointInField)
    }

    private func stopMouseMonitor() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        isDraggingPanel = false
        isFreezingDuringFinderMouseDrag = false
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        stopMouseEventTap()
    }

    private func stopMouseEventTap() {
        if let mouseEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseEventTapRunLoopSource, .commonModes)
            self.mouseEventTapRunLoopSource = nil
        }
        if let mouseEventTap {
            CGEvent.tapEnable(tap: mouseEventTap, enable: false)
            self.mouseEventTap = nil
        }
    }

    private func beginLongPressCandidate(with event: NSEvent) {
        guard !isEditingPath else { return }
        longPressWorkItem?.cancel()
        let pointInField = pathField.convert(event.locationInWindow, from: nil)
        guard pathField.bounds.contains(pointInField) else { return }
        // Use CG/AX only — AppleScript here re-enters the run loop mid-mouseDown.
        guard let finderFrame = frontFinderWindowBounds() else { return }
        guard let screen = screenContaining(finderFrame) ?? NSScreen.main else { return }
        let finderBounds = FinderBounds(
            left: finderFrame.minX,
            top: screen.frame.maxY - finderFrame.maxY,
            right: finderFrame.maxX,
            bottom: screen.frame.maxY - finderFrame.minY
        )

        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFinderBounds = finderBounds

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isDraggingPanel = true
            self.stopFollowingFinder()
            self.hideHistoryPanel()
        }
        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func dragPanel(with event: NSEvent) {
        guard let dragStartFinderBounds else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouseLocation.x
        let dy = current.y - dragStartMouseLocation.y
        let movedBounds = dragStartFinderBounds.offsetBy(dx: dx, dy: -dy)
        setFrontFinderBounds(movedBounds)
        updatePanelFrame()
    }

    private func endLongPressOrDrag() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil

        guard isDraggingPanel else { return }
        isDraggingPanel = false
        dragStartFinderBounds = nil
        beginFinderWindowTransition()
        startFollowingFinder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.updatePanelFrame(lightweight: true)
        }
    }

    private func refreshPathFromFinder(allowAppleScript: Bool = false) {
        updateAttachedFinderWindowID()
        if let path = currentFinderPath(allowAppleScript: allowAppleScript), !path.isEmpty {
            applyPathToUI(path)
            recordHistory(path)
        } else if pathField.stringValue.isEmpty {
            applyPathToUI(NSHomeDirectory())
        }
        updateBookmarkButton()
        updateNavigationButtonStates()
    }

    private func syncWithFinder() {
        // If Finder is frontmost, never keep following a background file dialog.
        if isFileDialogMode {
            if isFinderFrontmost {
                leaveFileDialogModeForFinder()
            } else if let dialog = findFrontFileDialog() {
                syncWithFileDialog(dialog)
                return
            } else {
                clearFileDialogMode()
                hidePanelAutomatically()
                return
            }
        }
        if isFreezingDuringFinderMouseDrag || isLiveTrackingFinderGeometry {
            // Live resize/move: keep width/position in sync without AX tree walks.
            updatePanelFrame(lightweight: true)
            return
        }
        if shouldHidePathBarForFinderDialog() {
            hidePathBarForFinderUtilityDialog()
            return
        }
        if hiddenForFinderUtilityDialog {
            hiddenForFinderUtilityDialog = false
            if !panel.isVisible, !manuallyHidden {
                presentPanel(focusAddressBar: false, createFinderWindow: false)
                return
            }
        }
        guard shouldUseFinderWindowContext else {
            hidePanelAutomatically()
            return
        }
        guard let finderWindowBounds = frontFinderWindowBounds() else {
            if shouldKeepPanelVisibleWhileFinderWindowChanges() { return }
            finderWindowUnavailableSince = nil
            attachedFinderWindowID = nil
            lastMainContentBounds = nil
            lastMainContentWindowID = nil
            lastFinderWindowBounds = nil
            pendingCollapsedSidebarContent = nil
            hidePanelAutomatically()
            return
        }
        finderWindowUnavailableSince = nil
        lastFinderWindowBounds = finderWindowBounds
        let now = Date()
        // Sync path often enough that double-click folder navigation feels instant.
        let shouldSyncPath = now.timeIntervalSince(lastPathSyncAt) >= 0.25 || isNavigatingHistory
        if shouldSyncPath, !isExecutingAppleScript {
            lastPathSyncAt = now
            updateAttachedFinderWindowID()
        }
        if isEditingPath || isEditingSearch {
            updatePanelFrame(lightweight: true)
            updateHistoryPanelFrame()
            return
        }
        // Prefer AppleScript for the Finder target path. AXDocument often stays on
        // the previous folder after double-click navigation (title updates, path does not).
        if shouldSyncPath, !isExecutingAppleScript,
           let path = currentFinderPath(allowAppleScript: true, preferAppleScript: true),
           !path.isEmpty {
            if path != normalizePath(pathField.stringValue) {
                applyPathToUI(path)
            }
            if isNavigatingHistory {
                updatePanelFrame(lightweight: true)
                updateHistoryPanelFrame()
                return
            }
            if let ignoreNextSyncRecordUntil, Date() < ignoreNextSyncRecordUntil {
                updatePanelFrame(lightweight: true)
                updateHistoryPanelFrame()
                return
            }
            self.ignoreNextSyncRecordUntil = nil
            recordHistory(path)
        }
        updateBookmarkButton()
        updateNavigationButtonStates()
        // Periodically remeasure AX content so sidebar show/hide updates FP width.
        // Lightweight passes preserve the last sidebar inset and would stay stuck.
        let needsContentRefresh = now.timeIntervalSince(lastContentBoundsSyncAt) >= 0.35
        updatePanelFrame(lightweight: !needsContentRefresh)
        updateHistoryPanelFrame()
    }

    private func updateNavigationButtonStates() {
        let canGoBack = historyIndex > 0
        let canGoForward = historyIndex >= 0 && historyIndex < history.count - 1
        let currentPath = normalizePath(pathField.stringValue)
        let canGoParent = !currentPath.isEmpty && currentPath != "/"
        setButton(backButton, enabled: canGoBack)
        setButton(forwardButton, enabled: canGoForward)
        setButton(parentButton, enabled: canGoParent)
    }

    private func setButton(_ button: NSButton, enabled: Bool) {
        button.isEnabled = enabled
        button.contentTintColor = enabled ? .labelColor : .disabledControlTextColor
        button.alphaValue = enabled ? 1 : 0.42
    }

    private func updatePanelFrame(lightweight: Bool = false) {
        guard !isDraggingPanel else { return }
        guard !isHidingOrDetachingPanel else { return }
        // Freeze while Finder inline-rename is active — AX/content remasurement
        // briefly reports a lower frame and makes the path bar drop into the list.
        if isFinderRenameHotKeysSuspended {
            return
        }
        // Replace / Keep Both / Get Info: temporarily hide so the dialog is clear.
        if shouldHidePathBarForFinderDialog() {
            hidePathBarForFinderUtilityDialog()
            return
        }
        guard shouldUseFinderWindowContext else {
            if panel.isVisible, !isAutoHideSuppressed {
                hidePanelAutomatically()
            }
            return
        }
        guard let frame = defaultPanelFrame(lightweight: lightweight) else { return }
        let wasVisible = panel.isVisible
        panel.setFrame(frame, display: true)
        let previousLevel = panel.level
        updatePanelLevelForCurrentApp()
        // Avoid orderFront on every follow-timer tick — it spams WindowServer and
        // has coincided with SIGSEGV when Excel/WPS activate over Finder.
        if panel.level == .floating, settingsPanel?.isVisible != true {
            if !wasVisible || previousLevel != panel.level {
                panel.orderFrontRegardless()
            }
        }
        updateToolbarMenuPanelFrame()
    }

    private func updatePanelLevelForCurrentApp() {
        if settingsPanel?.isVisible == true {
            panel.level = .normal
            return
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Never walk Finder's AX tree while another app is frontmost — that race
        // matches the SIGSEGV corpses when opening Excel/WPS/PPT from Finder.
        // File-dialog mode is an intentional exception: we attach above Open/Save.
        if isFileDialogMode {
            panel.level = .floating
            return
        }
        guard frontmostBundleID == "com.apple.finder" || frontmostBundleID == Bundle.main.bundleIdentifier else {
            panel.level = .normal
            return
        }
        panel.level = .floating
    }

    private func hidePathBarForFinderUtilityDialog() {
        guard !hiddenForFinderUtilityDialog || panel.isVisible else { return }
        if panel.isVisible {
            AppLogger.shared.log("hidePathBarForFinderUtilityDialog")
            hiddenForFinderUtilityDialog = true
            panel.orderOut(nil)
            hideHistoryPanel()
            hideToolbarMenu()
            hideAutocompletePanel()
            hideSearchPanel()
        } else {
            hiddenForFinderUtilityDialog = true
        }
    }

    /// Replace / Keep Both / Stop, Get Info, and similar Finder utility dialogs.
    private func shouldHidePathBarForFinderDialog() -> Bool {
        guard isFinderFrontmost || isFinderPathBarFrontmost || hiddenForFinderUtilityDialog else {
            return false
        }
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return false
        }
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return false
        }
        for window in windows {
            if isFinderUtilityDialogWindow(window) {
                return true
            }
            // Conflict prompts are often sheets on the Finder window.
            for sheet in axSheets(in: window) where isFinderUtilityDialogWindow(sheet) {
                return true
            }
        }
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focused = AXSafe.element(focusedValue),
           isFinderUtilityDialogWindow(focused) {
            return true
        }
        return false
    }

    private func isFinderUtilityDialogWindow(_ window: AXUIElement) -> Bool {
        let title = (axTitle(window) ?? "").lowercased()
        if title.contains("简介") || title.contains("get info") || title.hasSuffix(" info") {
            return true
        }

        let buttonTitles = collectButtonTitles(in: window, limit: 24)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasReplace = buttonTitles.contains { $0 == "替换" || $0 == "replace" }
        let hasKeepBoth = buttonTitles.contains { $0 == "保留两者" || $0 == "keep both" }
        let hasStop = buttonTitles.contains { $0 == "停止" || $0 == "stop" }
        // Finder copy/move conflict sheet: Replace / Keep Both / Stop
        if hasReplace || hasKeepBoth || hasStop {
            return true
        }
        return false
    }

    private func isFinderShowingFloatingWindow() -> Bool {
        shouldHidePathBarForFinderDialog()
    }

    private var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    private var isFinderPathBarFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private var shouldUseFinderWindowContext: Bool {
        // Clicking the path bar / bookmarks activates FinderPathBar. Keep the
        // bar up in that case — requiring an attached window ID made it hide
        // as soon as Finder finished (or briefly lost) focus.
        if isFileDialogMode {
            return true
        }
        if isFinderFrontmost || isFinderPathBarFrontmost {
            return true
        }
        if panel.isVisible, isNavigatingHistory || isEditingPath || isNavigatingFileDialog {
            return true
        }
        return false
    }

    private func defaultPanelFrame(lightweight: Bool = false) -> NSRect? {
        if isFileDialogMode {
            return defaultFileDialogPanelFrame()
        }
        let now = Date()
        // While Finder is mid-navigation, AX content scans are unreliable and
        // often fall back to the full window (including the sidebar). Prefer the
        // last known main-content alignment until Finder settles.
        let forceStableAlignment = isNavigatingHistory || lightweight
        let shouldRefreshContentBounds = !forceStableAlignment
            && (now.timeIntervalSince(lastContentBoundsSyncAt) >= 0.08 || lastMainContentBounds == nil)

        let currentWindowFrame = frontFinderWindowBounds()
        if let currentWindowFrame {
            if let previousWindowBounds = lastFinderWindowBounds,
               let previousContentBounds = lastMainContentBounds {
                let dx = currentWindowFrame.minX - previousWindowBounds.minX
                let dy = currentWindowFrame.maxY - previousWindowBounds.maxY
                let dw = currentWindowFrame.width - previousWindowBounds.width
                let dh = currentWindowFrame.height - previousWindowBounds.height

                if abs(dw) > 0.5 || abs(dh) > 0.5 {
                    // Live resize: keep sidebar insets, recompute width/height now.
                    // Previously we only translated by dx/dy, so width stayed stale
                    // until an app-switch forced a full AX refresh.
                    lastMainContentBounds = contentFramePreservingInsets(
                        previousContent: previousContentBounds,
                        previousWindow: previousWindowBounds,
                        newWindow: currentWindowFrame
                    )
                } else if dx != 0 || dy != 0 {
                    lastMainContentBounds = previousContentBounds.offsetBy(dx: dx, dy: dy)
                }
            }
            lastFinderWindowBounds = currentWindowFrame
        }

        let windowID = shouldRefreshContentBounds
            ? (axFrontFinderWindowID() ?? attachedFinderWindowID)
            : attachedFinderWindowID
        var contentFrame: NSRect? = nil
        if shouldRefreshContentBounds {
            lastContentBoundsSyncAt = now
            if let measured = frontFinderContentBounds(),
               isPlausibleMainContentFrame(measured, windowFrame: currentWindowFrame ?? lastFinderWindowBounds) {
                contentFrame = measured
                lastMainContentBounds = measured
                if let windowID {
                    lastMainContentWindowID = windowID
                }
            }
        }

        // Prefer: fresh content → cached content → derived from window+sidebar inset → full window
        let finderFrame = contentFrame
            ?? lastMainContentBounds
            ?? derivedMainContentFrame(from: currentWindowFrame ?? lastFinderWindowBounds)
            ?? currentWindowFrame
            ?? lastFinderWindowBounds
        guard let finderFrame else { return nil }

        // Always pin vertically to the Finder *window* top — never to content
        // bounds. Content maxY sits below the toolbar, which drops FP into the list.
        guard let verticalFrame = currentWindowFrame ?? lastFinderWindowBounds else { return nil }
        let width = max(360, finderFrame.width - horizontalInset * 2)
        let x = finderFrame.minX + horizontalInset
        let y = verticalFrame.maxY + verticalGap
        let height = currentPanelHeight(forWidth: width)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Reject transient AX hits that look like the full Finder window (no sidebar inset).
    /// Real sidebar hide looks the same geometrically, so require a second consistent reading
    /// (or accept immediately when Finder is idle / not mid-navigation).
    private func isPlausibleMainContentFrame(_ content: NSRect, windowFrame: NSRect?) -> Bool {
        guard let windowFrame, windowFrame.width > 0 else { return true }
        let leftInset = content.minX - windowFrame.minX
        let widthRatio = content.width / windowFrame.width
        let looksValid = content.width >= 360 && content.maxX <= windowFrame.maxX + 12

        // A real list/column view is usually inset by the sidebar.
        if let previous = lastMainContentBounds {
            let previousInset = previous.minX - (lastFinderWindowBounds?.minX ?? windowFrame.minX)
            if previousInset > 80, leftInset < 40, widthRatio > 0.92 {
                // Navigation can briefly report the full window; keep the old inset then.
                if isNavigatingHistory {
                    pendingCollapsedSidebarContent = nil
                    return false
                }
                // Sidebar toggle: confirm with two matching measurements before committing.
                if let pending = pendingCollapsedSidebarContent,
                   abs(pending.minX - content.minX) < 12,
                   abs(pending.width - content.width) < 24 {
                    pendingCollapsedSidebarContent = nil
                    return looksValid
                }
                pendingCollapsedSidebarContent = content
                return false
            }
        } else if leftInset < 40, widthRatio > 0.95 {
            // First measurement that spans almost the whole window is fine only
            // when Finder has no sidebar; still accept it to avoid empty state.
            pendingCollapsedSidebarContent = nil
            return true
        }
        pendingCollapsedSidebarContent = nil
        return looksValid
    }

    /// Keep sidebar inset stable when AX content bounds are temporarily unavailable.
    private func derivedMainContentFrame(from windowFrame: NSRect?) -> NSRect? {
        guard let windowFrame,
              let previousContent = lastMainContentBounds,
              let previousWindow = lastFinderWindowBounds,
              previousWindow.width > 0 else {
            return nil
        }
        return contentFramePreservingInsets(
            previousContent: previousContent,
            previousWindow: previousWindow,
            newWindow: windowFrame
        )
    }

    private func contentFramePreservingInsets(
        previousContent: NSRect,
        previousWindow: NSRect,
        newWindow: NSRect
    ) -> NSRect {
        let leftInset = max(0, previousContent.minX - previousWindow.minX)
        let rightInset = max(0, previousWindow.maxX - previousContent.maxX)
        let topInset = max(0, previousWindow.maxY - previousContent.maxY)
        let bottomInset = max(0, previousContent.minY - previousWindow.minY)
        return NSRect(
            x: newWindow.minX + leftInset,
            y: newWindow.minY + bottomInset,
            width: max(360, newWindow.width - leftInset - rightInset),
            height: max(1, newWindow.height - topInset - bottomInset)
        )
    }

    private func currentPanelHeight(forWidth width: CGFloat) -> CGFloat {
        let trailingChrome: CGFloat = 22 + 22 + 22 + (isSearchExpanded ? 154 : 0) + 24
        let pathWidth = max(120, width - buttonStackWidthEstimate - trailingChrome)
        let text = pathField.stringValue.isEmpty ? pathField.placeholderString ?? "" : pathField.stringValue
        let font = pathField.font ?? .monospacedSystemFont(ofSize: pathFontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = max(1, (text as NSString).size(withAttributes: attributes).width)
        let lineCount = min(maxPathLines, max(1, ceil(textWidth / pathWidth)))
        let fieldHeight = max(25, lineCount * (font.ascender - font.descender + font.leading) + 6)
        pathFieldHeightConstraint?.constant = fieldHeight
        return max(24, max(barHeight, iconHeight, fieldHeight + 8) + secondToolbarHeight + effectiveBookmarksToolbarHeight + panelHeightOffset)
    }

    private var buttonStackWidthEstimate: CGFloat {
        // Row 1 stack: x + Xo + Xa + ⚙ < > ^
        let closeWidth: CGFloat = 22
        let extraCloseWidth: CGFloat = 26
        let navWidth: CGFloat = 22
        let spacing: CGFloat = 3
        return closeWidth + extraCloseWidth * 2 + navWidth * 4 + spacing * 6 + 15
    }

    private func showHistoryPanelBelowAddressBar() {
        suppressAutoHide(duration: 60)
        if historyPanel == nil {
            historyPanel = makeHistoryPanel()
        }
        historyListView?.configure(
            entries: visibleHistory,
            formatter: historyDateFormatter,
            pathFontSize: pathFontSize,
            backgroundColor: NSColor(hex: dropdownBackgroundColorHex),
            emptyText: localized("No history", "无历史地址"),
            onSelect: { [weak self] path in
                self?.openHistoryPath(path)
            }
        )
        updateHistoryPanelFrame()
        historyPanel?.orderFrontRegardless()
        historyPanel?.displayIfNeeded()
    }

    private func hideHistoryPanel(clearSuppression: Bool = true) {
        historyPanel?.orderOut(nil)
        if clearSuppression {
            suppressAutoHideUntil = nil
        }
    }

    private func updateHistoryPanelFrame() {
        guard let historyPanel, panel.isVisible else { return }
        let height = visibleHistory.isEmpty ? 26 : min(CGFloat(visibleHistory.count) * 26, 234)
        historyPanel.setFrame(
            NSRect(x: panel.frame.minX, y: panel.frame.minY - height, width: panel.frame.width, height: height),
            display: true
        )
    }

    private func openPathComponent(at characterIndex: Int) {
        let path = pathField.stringValue
        guard path.hasPrefix("/") else { return }
        let chars = Array(path)
        let clamped = min(max(characterIndex, 0), max(chars.count - 1, 0))
        if clamped == 0 {
            jumpToPathComponent("/")
            return
        }
        var start = clamped
        while start > 0 && chars[start] == "/" {
            start -= 1
        }
        while start > 0 && chars[start] != "/" {
            start -= 1
        }
        var end = max(start + 1, clamped)
        while end < chars.count && chars[end] != "/" {
            end += 1
        }

        let componentPath: String
        if start == 0 && end == 1 && chars[0] == "/" {
            componentPath = "/"
        } else {
            componentPath = String(chars[0..<end])
        }

        jumpToPathComponent(componentPath)
    }

    private func jumpToPathComponent(_ componentPath: String) {
        endPathEditing()
        navigateFinder(to: componentPath, source: "path-component")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refocusAttachedFinderWindow(activateFinder: true)
        }
    }

    private func applyAppearanceSettings() {
        backgroundView.layer?.backgroundColor = NSColor(hex: backgroundColorHex).cgColor
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        historyBackgroundView?.layer?.backgroundColor = NSColor(hex: dropdownBackgroundColorHex).cgColor
        pathField.font = .monospacedSystemFont(ofSize: pathFontSize, weight: .regular)
        for button in iconButtons {
            if button === closeButton {
                applyCloseGlyph(button, suffix: nil)
            } else if button === closeOthersButton {
                applyCloseGlyph(button, suffix: "o")
            } else if button === closeAllButton {
                applyCloseGlyph(button, suffix: "a")
            } else {
                button.font = .systemFont(ofSize: iconSize, weight: .semibold)
            }
        }
        for button in secondToolbarButtons {
            button.font = .systemFont(ofSize: pathFontSize, weight: .regular)
        }
        applyNewItemButtonTypes()
        for constraint in iconButtonHeightConstraints {
            constraint.constant = iconHeight
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        stackCenterYConstraint.constant = pathRowCenterYFromBottom
        historyCenterYConstraint.constant = pathRowCenterYFromBottom
        bookmarkCenterYConstraint.constant = pathRowCenterYFromBottom
        searchButtonCenterYConstraint?.constant = pathRowCenterYFromBottom
        searchCenterYConstraint?.constant = pathRowCenterYFromBottom + textYOffset
        fieldCenterYConstraint.constant = pathRowCenterYFromBottom + textYOffset
        for button in bookmarkFolderButtons {
            button.font = .systemFont(ofSize: pathFontSize, weight: .regular)
        }
        bookmarksEmptyLabel?.font = .systemFont(ofSize: max(10, pathFontSize - 1), weight: .regular)
        searchField?.font = .systemFont(ofSize: max(11, pathFontSize - 1), weight: .regular)
        searchField?.placeholderString = localized("Name/folder keywords (AND)…", "搜文件名与文件夹名；空格=同时匹配")
        updateSearchButtonAppearance()
        applyBookmarksToolbarLayout()
        updatePathChromeVisibility()
        updatePanelFrame()
    }

    private func makeSettingsPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = localized("FinderPathBar Settings", "FinderPathBar 设置")
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel

        let appearanceView = makeAppearanceSettingsView()
        appearanceView.translatesAutoresizingMaskIntoConstraints = false

        let okButton = NSButton(title: localized("OK", "确定"), target: self, action: #selector(confirmSettings))
        okButton.bezelStyle = .rounded
        okButton.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView?.addSubview(appearanceView)
        panel.contentView?.addSubview(okButton)
        NSLayoutConstraint.activate([
            appearanceView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            appearanceView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            appearanceView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            appearanceView.bottomAnchor.constraint(equalTo: okButton.topAnchor, constant: -8),
            okButton.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18),
            okButton.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -14)
        ])
        return panel
    }

    private func makeAppearanceSettingsView() -> NSView {
        let contentView = NSView()

        let sizingRow = NSStackView(views: [
            makeNumberControl(title: localized("Icon", "图标"), value: iconSize, fieldAction: #selector(iconSizeChanged(_:)), stepperAction: #selector(iconSizeStepperChanged(_:))),
            makeNumberControl(title: localized("Icon H", "图标高"), value: iconHeight, fieldAction: #selector(iconHeightChanged(_:)), stepperAction: #selector(iconHeightStepperChanged(_:))),
            makeNumberControl(title: localized("Text", "文字"), value: pathFontSize, fieldAction: #selector(pathFontSizeChanged(_:)), stepperAction: #selector(pathFontSizeStepperChanged(_:))),
            makeNumberControl(title: localized("Y", "上下"), value: textYOffset, fieldAction: #selector(textYOffsetChanged(_:)), stepperAction: #selector(textYOffsetStepperChanged(_:))),
            makeNumberControl(title: localized("Height", "高度"), value: panelHeightOffset, fieldAction: #selector(panelHeightOffsetChanged(_:)), stepperAction: #selector(panelHeightOffsetStepperChanged(_:)))
        ])
        sizingRow.orientation = .horizontal
        sizingRow.spacing = 10
        sizingRow.distribution = .gravityAreas
        sizingRow.setHuggingPriority(.required, for: .horizontal)
        let colorField = NSTextField(string: backgroundColorHex)
        colorField.delegate = self
        colorField.isEditable = true
        colorField.isSelectable = true
        colorField.target = self
        colorField.action = #selector(backgroundColorChanged(_:))
        (colorField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        colorField.translatesAutoresizingMaskIntoConstraints = false
        colorField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let colorWell = NSColorWell()
        colorWell.color = NSColor(hex: backgroundColorHex)
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        settingsBackgroundColorField = colorField
        settingsBackgroundColorWell = colorWell

        let colorRow = NSStackView(views: [colorField, colorWell])
        colorRow.orientation = .horizontal
        colorRow.spacing = 8
        colorRow.setHuggingPriority(.required, for: .horizontal)

        let dropdownColorField = NSTextField(string: dropdownBackgroundColorHex)
        dropdownColorField.delegate = self
        dropdownColorField.isEditable = true
        dropdownColorField.isSelectable = true
        dropdownColorField.target = self
        dropdownColorField.action = #selector(dropdownBackgroundColorChanged(_:))
        (dropdownColorField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        dropdownColorField.translatesAutoresizingMaskIntoConstraints = false
        dropdownColorField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let dropdownColorWell = NSColorWell()
        dropdownColorWell.color = NSColor(hex: dropdownBackgroundColorHex)
        dropdownColorWell.target = self
        dropdownColorWell.action = #selector(dropdownColorWellChanged(_:))
        dropdownColorWell.translatesAutoresizingMaskIntoConstraints = false
        dropdownColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        settingsDropdownColorField = dropdownColorField
        settingsDropdownColorWell = dropdownColorWell

        let dropdownColorRow = NSStackView(views: [dropdownColorField, dropdownColorWell])
        dropdownColorRow.orientation = .horizontal
        dropdownColorRow.spacing = 8
        dropdownColorRow.setHuggingPriority(.required, for: .horizontal)

        let dropdownLabel = NSTextField(labelWithString: localized("Menu Bg", "下拉背景"))
        dropdownLabel.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let colorCombinedRow = NSStackView(views: [colorRow, dropdownLabel, dropdownColorRow])
        colorCombinedRow.orientation = .horizontal
        colorCombinedRow.spacing = 18
        colorCombinedRow.alignment = .centerY
        colorCombinedRow.setHuggingPriority(.required, for: .horizontal)

        let launchAtLoginCheckbox = makeSettingsCheckbox(title: localized("Launch at Login", "开机启动"), state: launchesAtLogin, action: #selector(launchAtLoginChanged(_:)))
        launchAtLoginCheckbox.state = launchesAtLogin ? .on : .off
        launchAtLoginCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        let currentTypes = newItemButtonTypes
        settingsNewItemTypeFields = (0..<6).map { index in
            let field = NSTextField(string: currentTypes[index])
            field.placeholderString = defaultNewItemButtonTypes[index]
            field.font = .systemFont(ofSize: 12)
            field.alignment = .center
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            field.toolTip = localized(
                "dir = folder; otherwise file extension (md, csv…)",
                "dir=新建文件夹；其它填后缀（如 md、csv）"
            )
            return field
        }
        let newItemTypesRow = NSStackView(views: settingsNewItemTypeFields)
        newItemTypesRow.orientation = .horizontal
        newItemTypesRow.spacing = 6
        newItemTypesRow.alignment = .centerY
        let newItemHint = NSTextField(wrappingLabelWithString: localized(
            "dir = folder; other values are file extensions",
            "dir=文件夹，其它为文件后缀"
        ))
        newItemHint.font = .systemFont(ofSize: 11)
        newItemHint.textColor = .secondaryLabelColor
        newItemHint.translatesAutoresizingMaskIntoConstraints = false
        let newItemTypesBlock = NSStackView(views: [newItemTypesRow, newItemHint])
        newItemTypesBlock.orientation = .vertical
        newItemTypesBlock.spacing = 4
        newItemTypesBlock.alignment = .leading

        let languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["English", "中文"])
        languagePopup.selectItem(at: isChineseLanguage ? 1 : 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let checkUpdateButton = NSButton(title: localized("Check for Updates", "检查更新"), target: self, action: #selector(checkForAppUpdatesFromSettings))
        checkUpdateButton.bezelStyle = .rounded
        let updateStatus = NSTextField(labelWithString: localized(
            "v\(currentVersion) · auto-check monthly",
            "当前版本 \(currentVersion) · 每月自动检查"
        ))
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.translatesAutoresizingMaskIntoConstraints = false
        settingsUpdateStatusLabel = updateStatus
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 240).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 12).isActive = true
        settingsUpdateProgress = progress
        let updateRow = NSStackView(views: [checkUpdateButton, updateStatus])
        updateRow.orientation = .horizontal
        updateRow.spacing = 10
        updateRow.alignment = .centerY
        let updateBlock = NSStackView(views: [updateRow, progress])
        updateBlock.orientation = .vertical
        updateBlock.spacing = 6
        updateBlock.alignment = .leading

        let feedbackLabel = NSTextField(wrappingLabelWithString: localized("Please send \(AppLogger.shared.logURL.path) to zj391120@163.com", "请把 \(AppLogger.shared.logURL.path) 发送给 zj391120@163.com"))
        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.maximumNumberOfLines = 2
        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        feedbackLabel.widthAnchor.constraint(equalToConstant: 570).isActive = true

        let rows: [(String, NSView)] = [
            (localized("Language", "语言"), languagePopup),
            (localized("Size", "尺寸位置"), sizingRow),
            (localized("Colors", "背景颜色"), colorCombinedRow),
            (localized("New files", "新建类型"), newItemTypesBlock),
            (localized("Startup", "启动设置"), launchAtLoginCheckbox),
            (localized("Updates", "软件更新"), updateBlock),
            (localized("Feedback", "反馈信息"), feedbackLabel)
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 74).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18)
        ])
        return contentView
    }

    private func makeSettingsCheckbox(title: String, state: Bool, action: Selector) -> NSButton {
        let button = FirstMouseCheckbox(title: title, target: self, action: action)
        button.setButtonType(.switch)
        button.state = state ? .on : .off
        button.isEnabled = true
        button.allowsMixedState = false
        return button
    }

    private func makeNumberControl(title: String, value: CGFloat, fieldAction: Selector, stepperAction: Selector) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: String(format: "%.1f", Double(value)))
        field.target = self
        field.action = fieldAction
        field.identifier = NSUserInterfaceItemIdentifier(title)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let stepper = NSStepper()
        stepper.minValue = -Double.greatestFiniteMagnitude
        stepper.maxValue = Double.greatestFiniteMagnitude
        stepper.increment = 1
        stepper.doubleValue = Double(value)
        stepper.target = self
        stepper.action = stepperAction
        stepper.identifier = NSUserInterfaceItemIdentifier(title)
        stepper.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, field, stepper])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }

    @objc private func iconSizeChanged(_ sender: NSTextField) {
        defaults.set(sender.doubleValue, forKey: "iconSize")
        applyAppearanceSettings()
    }

    @objc private func iconSizeStepperChanged(_ sender: NSStepper) {
        defaults.set(sender.doubleValue, forKey: "iconSize")
        updateNumberField(matching: sender, value: sender.doubleValue)
        applyAppearanceSettings()
    }

    @objc private func iconHeightChanged(_ sender: NSTextField) {
        defaults.set(sender.doubleValue, forKey: "iconHeight")
        applyAppearanceSettings()
    }

    @objc private func iconHeightStepperChanged(_ sender: NSStepper) {
        defaults.set(sender.doubleValue, forKey: "iconHeight")
        updateNumberField(matching: sender, value: sender.doubleValue)
        applyAppearanceSettings()
    }

    @objc private func pathFontSizeChanged(_ sender: NSTextField) {
        defaults.set(sender.doubleValue, forKey: "pathFontSize")
        applyAppearanceSettings()
    }

    @objc private func pathFontSizeStepperChanged(_ sender: NSStepper) {
        defaults.set(sender.doubleValue, forKey: "pathFontSize")
        updateNumberField(matching: sender, value: sender.doubleValue)
        applyAppearanceSettings()
    }

    @objc private func textYOffsetChanged(_ sender: NSTextField) {
        defaults.set(sender.doubleValue, forKey: "textYOffset")
        applyAppearanceSettings()
    }

    @objc private func textYOffsetStepperChanged(_ sender: NSStepper) {
        defaults.set(sender.doubleValue, forKey: "textYOffset")
        updateNumberField(matching: sender, value: sender.doubleValue)
        applyAppearanceSettings()
    }

    @objc private func panelHeightOffsetChanged(_ sender: NSTextField) {
        defaults.set(sender.doubleValue, forKey: "panelHeightOffset")
        applyAppearanceSettings()
    }

    @objc private func panelHeightOffsetStepperChanged(_ sender: NSStepper) {
        defaults.set(sender.doubleValue, forKey: "panelHeightOffset")
        updateNumberField(matching: sender, value: sender.doubleValue)
        applyAppearanceSettings()
    }

    private func updateNumberField(matching stepper: NSStepper, value: Double) {
        guard let identifier = stepper.identifier,
              let field = settingsPanel?.contentView?.firstDescendant(where: { view in
                  (view as? NSTextField)?.identifier == identifier
              }) as? NSTextField else {
            return
        }
        field.stringValue = String(format: "%.1f", value)
    }

    @objc private func backgroundColorChanged(_ sender: NSTextField) {
        commitSettingsBackgroundColor(from: sender)
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        let hex = sender.color.hexString
        defaults.set(hex, forKey: "backgroundColor")
        if settingsBackgroundColorField?.stringValue.caseInsensitiveCompare(hex) != .orderedSame {
            settingsBackgroundColorField?.stringValue = hex
        }
        applyAppearanceSettings()
    }

    @objc private func dropdownBackgroundColorChanged(_ sender: NSTextField) {
        commitSettingsDropdownColor(from: sender)
    }

    @objc private func dropdownColorWellChanged(_ sender: NSColorWell) {
        let hex = sender.color.hexString
        defaults.set(hex, forKey: "dropdownBackgroundColor")
        if settingsDropdownColorField?.stringValue.caseInsensitiveCompare(hex) != .orderedSame {
            settingsDropdownColorField?.stringValue = hex
        }
        applyAppearanceSettings()
        historyListView?.setBackgroundColor(NSColor(hex: dropdownBackgroundColorHex))
    }

    private func commitSettingsBackgroundColor(from field: NSTextField) {
        guard let hex = parsedHexColorString(field.stringValue) else { return }
        if field.stringValue != hex {
            field.stringValue = hex
        }
        guard hex.caseInsensitiveCompare(backgroundColorHex) != .orderedSame
                || settingsBackgroundColorWell?.color.hexString.caseInsensitiveCompare(hex) != .orderedSame else {
            return
        }
        defaults.set(hex, forKey: "backgroundColor")
        syncColorWell(settingsBackgroundColorWell, toHex: hex)
        applyAppearanceSettings()
    }

    private func commitSettingsDropdownColor(from field: NSTextField) {
        guard let hex = parsedHexColorString(field.stringValue) else { return }
        if field.stringValue != hex {
            field.stringValue = hex
        }
        guard hex.caseInsensitiveCompare(dropdownBackgroundColorHex) != .orderedSame
                || settingsDropdownColorWell?.color.hexString.caseInsensitiveCompare(hex) != .orderedSame else {
            return
        }
        defaults.set(hex, forKey: "dropdownBackgroundColor")
        syncColorWell(settingsDropdownColorWell, toHex: hex)
        applyAppearanceSettings()
        historyListView?.setBackgroundColor(NSColor(hex: dropdownBackgroundColorHex))
    }

    private func parsedHexColorString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6, Int(body, radix: 16) != nil else { return nil }
        return "#" + body.lowercased()
    }

    private func syncColorWell(_ well: NSColorWell?, toHex hex: String) {
        guard let well else { return }
        let color = NSColor(hex: hex)
        if well.color.hexString.caseInsensitiveCompare(hex) != .orderedSame {
            well.color = color
        }
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let shouldEnable = sender.state == .on
        if #available(macOS 13.0, *) {
            do {
                if shouldEnable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                defaults.set(shouldEnable, forKey: "launchAtLogin")
            } catch {
                sender.state = launchesAtLogin ? .on : .off
                NSSound.beep()
                showCloseFailure(localized("Settings failed", "设置失败"))
            }
        } else {
            sender.state = .off
            defaults.set(false, forKey: "launchAtLogin")
            NSSound.beep()
            showCloseFailure(localized("Requires macOS 13", "需要macOS13"))
        }
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        defaults.set(sender.indexOfSelectedItem == 1 ? "zh" : "en", forKey: "languageCode")
        configureStatusItem()
        settingsPanel?.orderOut(nil)
        settingsPanel = makeSettingsPanel()
        settingsPanel?.center()
        settingsPanel?.level = .modalPanel
        settingsPanel?.makeKeyAndOrderFront(nil)
    }

    @objc private func confirmSettings() {
        // Persist custom new-file toolbar types before dismissing.
        if !settingsNewItemTypeFields.isEmpty {
            newItemButtonTypes = settingsNewItemTypeFields.map(\.stringValue)
            applyNewItemButtonTypes()
        }
        // The original short suppression may have expired while Settings was
        // open. Keep FP attached while Finder regains focus after dismissal.
        beginFinderWindowTransition()
        settingsPanel?.orderOut(nil)
        settingsNewItemTypeFields.removeAll()
        endPathEditing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.refocusAttachedFinderWindow(activateFinder: true)
            self.updatePanelLevelForCurrentApp()
            self.manuallyHidden = false
            self.startFollowingFinder()
            self.startMouseMonitor()
            self.autoAttachIfNeeded()
            self.updateHotKeyRegistrationForFrontmostApp()
        }
    }

    @objc private func checkForAppUpdatesFromSettings() {
        checkForAppUpdates(force: true, interactive: true)
    }

    /// Periodic check: at most once per calendar month of runtime checks (~30 days).
    private func scheduleMonthlyUpdateCheckIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkForAppUpdates(force: false, interactive: false)
        }
    }

    private var lastAppUpdateCheckAt: Date? {
        get { defaults.object(forKey: "lastAppUpdateCheckAt") as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: "lastAppUpdateCheckAt")
            } else {
                defaults.removeObject(forKey: "lastAppUpdateCheckAt")
            }
        }
    }

    private var monthlyUpdateCheckInterval: TimeInterval { 30 * 24 * 60 * 60 }

    /// Check GitHub Releases. New version → ask before downloading/installing.
    private func checkForAppUpdates(force: Bool, interactive: Bool) {
        if !force, let last = lastAppUpdateCheckAt,
           Date().timeIntervalSince(last) < monthlyUpdateCheckInterval {
            AppLogger.shared.log("update check skipped: last=\(last)")
            return
        }
        if isCheckingForUpdates {
            if interactive {
                setUpdateStatus(localized("Checking…", "正在检查…"))
            }
            return
        }
        isCheckingForUpdates = true
        if interactive {
            setUpdateStatus(localized("Checking for updates…", "正在检查更新…"))
        }

        fetchLatestReleaseInfo { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.isCheckingForUpdates = false }

                switch result {
                case .failure(let error):
                    AppLogger.shared.log("update check failed: \(error.localizedDescription)")
                    if interactive {
                        self.setUpdateStatus(self.localized("Check failed", "检查失败"))
                        self.showCloseFailure(self.localized(
                            "Couldn't check for updates: \(error.localizedDescription)",
                            "无法检查更新：\(error.localizedDescription)"
                        ))
                    }
                case .success(let release):
                    self.lastAppUpdateCheckAt = Date()
                    let remoteVersion = release.version
                    let localVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                    AppLogger.shared.log("update check local=\(localVersion) remote=\(remoteVersion) source=\(release.source)")

                    guard self.compareVersion(remoteVersion, greaterThan: localVersion) else {
                        if interactive {
                            self.setUpdateStatus(self.localized("Up to date (\(localVersion))", "已是最新版本（\(localVersion)）"))
                            self.showCloseFailure(self.localized("Already the latest version", "已是最新版本"))
                        }
                        return
                    }

                    guard let downloadURL = release.downloadURL else {
                        if interactive {
                            self.setUpdateStatus(self.localized("No DMG in release", "新版本没有 DMG"))
                        }
                        return
                    }

                    self.setUpdateStatus(self.localized("Update \(remoteVersion) available", "发现新版本 \(remoteVersion)"))
                    self.promptToInstallUpdate(version: remoteVersion, downloadURL: downloadURL)
                }
            }
        }
    }

    private struct LatestReleaseInfo {
        let version: String
        let downloadURL: URL?
        let source: String
    }

    private func fetchLatestReleaseInfo(completion: @escaping (Result<LatestReleaseInfo, Error>) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "FinderPathBar/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (macOS)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
        let session = URLSession(configuration: config)

        func fail(_ message: String, code: Int = -1) -> Error {
            NSError(domain: "FinderPathBar.Update", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }

        // 1) GitHub API (ephemeral session avoids shared-cookie 403s).
        let apiURL = URL(string: "https://api.github.com/repos/yikeshu0611/FinderPathBar/releases/latest")!
        session.dataTask(with: apiURL) { data, response, error in
            if let release = self.decodeGitHubAPIRelease(data: data, response: response) {
                completion(.success(release))
                return
            }
            let apiStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            let apiError = error?.localizedDescription ?? "HTTP \(apiStatus)"
            AppLogger.shared.log("update API failed: \(apiError); trying HTML redirect fallback")

            // 2) Fallback: /releases/latest follows to .../tag/vX.Y.Z (no API quota).
            var latestRequest = URLRequest(url: URL(string: "https://github.com/yikeshu0611/FinderPathBar/releases/latest")!)
            latestRequest.httpMethod = "GET"
            latestRequest.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            latestRequest.setValue(
                "FinderPathBar/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (macOS)",
                forHTTPHeaderField: "User-Agent"
            )
            session.dataTask(with: latestRequest) { _, response, redirectError in
                if let version = self.versionFromGitHubLatestResponse(response),
                   let info = self.releaseInfo(version: version, source: "html-redirect") {
                    completion(.success(info))
                    return
                }

                AppLogger.shared.log("update HTML redirect failed: \(redirectError?.localizedDescription ?? "no location"); trying atom feed")

                // 3) Fallback: Atom feed.
                var atomRequest = URLRequest(url: URL(string: "https://github.com/yikeshu0611/FinderPathBar/releases.atom")!)
                atomRequest.setValue(
                    "FinderPathBar/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (macOS)",
                    forHTTPHeaderField: "User-Agent"
                )
                session.dataTask(with: atomRequest) { atomData, atomResponse, atomError in
                    if let version = self.versionFromAtomFeed(atomData),
                       let info = self.releaseInfo(version: version, source: "atom") {
                        completion(.success(info))
                        return
                    }
                    let atomStatus = (atomResponse as? HTTPURLResponse)?.statusCode ?? -1
                    let detail = atomError?.localizedDescription
                        ?? "API \(apiStatus); HTML failed; Atom HTTP \(atomStatus)"
                    completion(.failure(fail(detail, code: apiStatus)))
                }.resume()
            }.resume()
        }.resume()
    }

    private func decodeGitHubAPIRelease(data: Data?, response: URLResponse?) -> LatestReleaseInfo? {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, let data,
              let release = try? JSONDecoder().decode(GitHubReleaseInfo.self, from: data) else {
            if let data, let body = String(data: data, encoding: .utf8), !body.isEmpty {
                AppLogger.shared.log("update API body: \(body.prefix(240))")
            }
            return nil
        }
        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assetURL = release.assets
            .first(where: { $0.name.lowercased().hasSuffix(".dmg") })
            .flatMap { URL(string: $0.browser_download_url) }
            ?? URL(string: "https://github.com/yikeshu0611/FinderPathBar/releases/download/v\(version)/FinderPathBar-\(version).dmg")
        return LatestReleaseInfo(version: version, downloadURL: assetURL, source: "api")
    }

    private func versionFromGitHubLatestResponse(_ response: URLResponse?) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let location = http.value(forHTTPHeaderField: "Location")
            ?? http.url?.absoluteString
        guard let location,
              let range = location.range(of: "/tag/", options: .backwards) else {
            return nil
        }
        let tag = String(location[range.upperBound...])
            .split(separator: "/").first
            .map(String.init) ?? ""
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return version.isEmpty ? nil : version
    }

    private func versionFromAtomFeed(_ data: Data?) -> String? {
        guard let data, let xml = String(data: data, encoding: .utf8) else { return nil }
        // <id>tag:github.com,2008:Repository/…/releases/1.0.94</id> or link …/tag/v1.0.94
        if let tagRange = xml.range(of: "/tag/v") ?? xml.range(of: "/tag/") {
            let after = xml[tagRange.upperBound...]
            let tag = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
            let version = String(tag).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if !version.isEmpty { return version }
        }
        if let releaseRange = xml.range(of: "/releases/") {
            let after = xml[releaseRange.upperBound...]
            let token = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
            let version = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if compareVersion(version, greaterThan: "0") || version.contains(".") {
                return version
            }
        }
        return nil
    }

    private func releaseInfo(version: String, source: String) -> LatestReleaseInfo? {
        guard !version.isEmpty else { return nil }
        let url = URL(string: "https://github.com/yikeshu0611/FinderPathBar/releases/download/v\(version)/FinderPathBar-\(version).dmg")
        return LatestReleaseInfo(version: version, downloadURL: url, source: source)
    }

    private func promptToInstallUpdate(version: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = localized("Update Available", "发现新版本")
        alert.informativeText = localized(
            "FinderPathBar \(version) is available. Update now?\nThe app will download the installer and restart.",
            "FinderPathBar \(version) 可用，是否现在更新？\n确认后将下载安装包并重启应用。"
        )
        alert.addButton(withTitle: localized("Update", "更新"))
        alert.addButton(withTitle: localized("Later", "以后"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            AppLogger.shared.log("update declined version=\(version)")
            setUpdateStatus(localized("Update \(version) available", "有可用更新 \(version)"))
            return
        }
        setUpdateStatus(localized("Updating to \(version)…", "正在更新到 \(version)…"))
        showUpdateDownloadProgress(version: version, fraction: 0, received: 0, total: 0)
        downloadAndInstallUpdate(from: downloadURL, version: version)
    }

    private func setUpdateStatus(_ text: String) {
        settingsUpdateStatusLabel?.stringValue = text
    }

    private func showUpdateDownloadProgress(version: String, fraction: Double, received: Int64, total: Int64) {
        let percent = Int((fraction * 100).rounded())
        let label: String
        if total > 0 {
            label = localized(
                "Downloading \(version)… \(percent)% (\(byteCountString(received)) / \(byteCountString(total)))",
                "正在下载 \(version)… \(percent)%（\(byteCountString(received)) / \(byteCountString(total))）"
            )
        } else {
            label = localized("Downloading \(version)…", "正在下载 \(version)…")
        }
        setUpdateStatus(label)
        let applyBar: (NSProgressIndicator?) -> Void = { bar in
            guard let bar else { return }
            bar.isHidden = false
            if total > 0 {
                bar.isIndeterminate = false
                bar.stopAnimation(nil)
                bar.doubleValue = fraction
            } else {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            }
        }
        applyBar(settingsUpdateProgress)
        ensureUpdateProgressPanel()
        updateProgressLabel?.stringValue = label
        applyBar(updateProgressIndicator)
        if let panel = updateProgressPanel {
            positionUpdateProgressPanel(panel)
            panel.orderFrontRegardless()
        }
    }

    private func hideUpdateDownloadProgress() {
        settingsUpdateProgress?.stopAnimation(nil)
        settingsUpdateProgress?.isHidden = true
        settingsUpdateProgress?.doubleValue = 0
        updateProgressIndicator?.stopAnimation(nil)
        updateProgressPanel?.orderOut(nil)
    }

    private func ensureUpdateProgressPanel() {
        if updateProgressPanel != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = localized("Software Update", "软件更新")
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        updateProgressLabel = label

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        updateProgressIndicator = bar

        guard let content = panel.contentView else { return }
        content.addSubview(label)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bar.heightAnchor.constraint(equalToConstant: 12)
        ])
        updateProgressPanel = panel
    }

    private func positionUpdateProgressPanel(_ progressPanel: NSPanel) {
        if let settingsPanel, settingsPanel.isVisible {
            let frame = settingsPanel.frame
            progressPanel.setFrameOrigin(NSPoint(x: frame.midX - 180, y: frame.minY - 76))
            return
        }
        if panel.isVisible {
            let frame = panel.frame
            progressPanel.setFrameOrigin(NSPoint(x: frame.midX - 180, y: frame.minY - 76))
            return
        }
        progressPanel.center()
    }

    private func byteCountString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func compareVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for i in 0..<count {
            let a = i < left.count ? left[i] : 0
            let b = i < right.count ? right[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private func downloadAndInstallUpdate(from url: URL, version: String) {
        let downloader = UpdateDownloadController()
        updateDownloader = downloader
        downloader.onProgress = { [weak self] received, total in
            guard let self else { return }
            let fraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
            self.showUpdateDownloadProgress(version: version, fraction: fraction, received: received, total: total)
        }
        downloader.onFinish = { [weak self] result in
            guard let self else { return }
            self.updateDownloader = nil
            switch result {
            case .failure(let error):
                AppLogger.shared.log("update download failed: \(error.localizedDescription)")
                self.hideUpdateDownloadProgress()
                self.setUpdateStatus(self.localized("Download failed", "下载失败"))
                self.showCloseFailure(self.localized("Update download failed", "更新下载失败"))
            case .success(let location):
                let tempDMG = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FinderPathBar-\(version)-\(UUID().uuidString).dmg")
                do {
                    if FileManager.default.fileExists(atPath: tempDMG.path) {
                        try FileManager.default.removeItem(at: tempDMG)
                    }
                    try FileManager.default.moveItem(at: location, to: tempDMG)
                } catch {
                    AppLogger.shared.log("update move failed: \(error.localizedDescription)")
                    self.hideUpdateDownloadProgress()
                    self.setUpdateStatus(self.localized("Download failed", "下载失败"))
                    return
                }
                self.showUpdateDownloadProgress(version: version, fraction: 1, received: 1, total: 1)
                self.setUpdateStatus(self.localized("Installing \(version)…", "正在安装 \(version)…"))
                self.updateProgressLabel?.stringValue = self.localized("Installing \(version)…", "正在安装 \(version)…")
                self.installUpdate(fromDMG: tempDMG, version: version)
            }
        }
        downloader.start(url: url)
    }

    private func installUpdate(fromDMG dmgURL: URL, version: String) {
        let destination = updateInstallDestinationURL()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathBar-update-\(UUID().uuidString).sh")
        let logURL = AppLogger.shared.logURL.deletingLastPathComponent()
            .appendingPathComponent("update-install.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -euo pipefail
        LOG=\(bashSingleQuoted(logURL.path))
        PID=\(pid)
        DMG=\(bashSingleQuoted(dmgURL.path))
        DEST=\(bashSingleQuoted(destination.path))
        mkdir -p "$(dirname "$LOG")"
        exec >>"$LOG" 2>&1
        echo "==== $(date) version=\(version) start ===="
        echo "pid=$PID dest=$DEST dmg=$DMG"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        echo "app exited"
        sleep 1
        if /usr/bin/pgrep -x FinderPathBar >/dev/null 2>&1; then
          echo "stopping relaunched FinderPathBar"
          /usr/bin/pkill -x FinderPathBar || true
          sleep 0.5
        fi
        xattr -cr "$DMG" >/dev/null 2>&1 || true
        MOUNT="$(mktemp -d /tmp/FinderPathBar-mnt-XXXXXX)"
        echo "attaching to $MOUNT"
        hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
        APP="$MOUNT/FinderPathBar.app"
        if [[ ! -d "$APP" ]]; then
          echo "app not found in dmg"
          hdiutil detach "$MOUNT" -force -quiet || true
          exit 1
        fi
        NEW="${DEST}.updating"
        OLD="${DEST}.old"
        rm -rf "$NEW" "$OLD"
        mkdir -p "$(dirname "$DEST")"
        echo "copying to $NEW"
        ditto "$APP" "$NEW"
        xattr -cr "$NEW" >/dev/null 2>&1 || true
        hdiutil detach "$MOUNT" -force -quiet || true
        rmdir "$MOUNT" 2>/dev/null || true
        if [[ -d "$DEST" ]]; then
          mv "$DEST" "$OLD" || rm -rf "$DEST"
        fi
        mv "$NEW" "$DEST"
        rm -rf "$OLD" || true
        rm -f "$DMG"
        echo "opening $DEST"
        open "$DEST"
        echo "==== $(date) done ===="
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            AppLogger.shared.log("update script write failed: \(error.localizedDescription)")
            showCloseFailure(localized("Couldn't prepare installer", "无法准备安装脚本"))
            return
        }

        // Process.deinit kills a still-running child. Detach with nohup so the
        // installer survives both deallocation and NSApp.terminate.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [
            "-c",
            "nohup /bin/bash \(bashSingleQuoted(scriptURL.path)) >/dev/null 2>&1 &"
        ]
        do {
            try launcher.run()
            launcher.waitUntilExit()
            guard launcher.terminationStatus == 0 else {
                throw NSError(
                    domain: "FinderPathBar",
                    code: Int(launcher.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "installer launch status \(launcher.terminationStatus)"]
                )
            }
        } catch {
            AppLogger.shared.log("update script launch failed: \(error.localizedDescription)")
            showCloseFailure(localized("Couldn't start installer", "无法启动安装"))
            return
        }

        AppLogger.shared.log("update installing version=\(version) dest=\(destination.path)")
        settingsPanel?.orderOut(nil)
        showCloseFailure(localized("Installing update, app will restart…", "正在安装更新，应用即将重启…"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    private func bashSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func updateInstallDestinationURL() -> URL {
        let current = Bundle.main.bundleURL.standardizedFileURL
        let parent = current.deletingLastPathComponent()
        if current.path.hasPrefix("/Applications/") {
            return current
        }
        if FileManager.default.isWritableFile(atPath: parent.path) {
            return current
        }
        return URL(fileURLWithPath: "/Applications/FinderPathBar.app")
    }

    private func makeHistoryPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(hex: dropdownBackgroundColorHex).cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        historyBackgroundView = background

        let listView = HistoryListView()
        listView.translatesAutoresizingMaskIntoConstraints = false
        historyListView = listView

        let content = NSView()
        content.addSubview(background)
        content.addSubview(listView)
        panel.contentView = content
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            listView.topAnchor.constraint(equalTo: content.topAnchor),
            listView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        return panel
    }

    private func makeMessagePanel(message: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 118, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor
        background.layer?.cornerRadius = 8
        background.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(background)
        content.addSubview(label)
        panel.contentView = content
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
        return panel
    }

    // MARK: - Donation QR reminder

    private var hasDonated: Bool {
        get { defaults.bool(forKey: "hasDonated") }
        set { defaults.set(newValue, forKey: "hasDonated") }
    }

    /// Hide tip popup until this date ("1天后出现").
    private var donationHiddenUntil: Date? {
        get { defaults.object(forKey: "donationHiddenUntil") as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: "donationHiddenUntil")
            } else {
                defaults.removeObject(forKey: "donationHiddenUntil")
            }
        }
    }

    private var isDonationTemporarilyHidden: Bool {
        guard let until = donationHiddenUntil else { return false }
        if Date() >= until {
            donationHiddenUntil = nil
            return false
        }
        return true
    }

    private func startDonationReminderIfNeeded() {
        stopDonationReminder()
        guard !hasDonated else {
            AppLogger.shared.log("donation reminder skipped: already donated")
            return
        }
        if isDonationTemporarilyHidden, let until = donationHiddenUntil {
            donationAwaitingFPPanel = false
            scheduleNextDonationReminder(after: max(1, until.timeIntervalSinceNow))
            AppLogger.shared.log("donation reminder deferred until \(until)")
            return
        }
        // Do not show during Accessibility prompt / launch — wait until FP panel appears with Finder.
        donationAwaitingFPPanel = true
        AppLogger.shared.log("donation reminder armed: wait for FP panel after Finder opens")
    }

    private func maybeShowDonationAfterFPAppeared() {
        guard donationAwaitingFPPanel else { return }
        guard !hasDonated, !isDonationTemporarilyHidden else {
            donationAwaitingFPPanel = false
            return
        }
        guard panel.isVisible else { return }
        donationAwaitingFPPanel = false
        // Let user see the path bar first, then tip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.tryShowDonationReminder()
        }
    }

    private func tryShowDonationReminder() {
        guard !hasDonated, !isDonationTemporarilyHidden else { return }
        if donationPanel?.isVisible == true { return }
        guard panel.isVisible else {
            donationAwaitingFPPanel = true
            AppLogger.shared.log("donation reminder deferred: FP panel not visible yet")
            return
        }
        showDonationPanel(triggeredByReminder: true)
    }

    private func stopDonationReminder() {
        donationReminderTimer?.invalidate()
        donationReminderTimer = nil
    }

    private func scheduleNextDonationReminder(after seconds: TimeInterval) {
        stopDonationReminder()
        guard !hasDonated else { return }
        let timer = Timer(timeInterval: max(1, seconds), repeats: false) { [weak self] _ in
            guard let self, !self.hasDonated else { return }
            if self.isDonationTemporarilyHidden {
                if let until = self.donationHiddenUntil {
                    self.scheduleNextDonationReminder(after: max(1, until.timeIntervalSinceNow))
                }
                return
            }
            self.tryShowDonationReminder()
        }
        donationReminderTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        AppLogger.shared.log("donation reminder scheduled in \(Int(seconds))s")
    }

    @objc private func showDonationPanelFromMenu() {
        showDonationPanel(triggeredByReminder: false)
    }

    private func showDonationPanel(triggeredByReminder: Bool) {
        if triggeredByReminder, hasDonated { return }
        if triggeredByReminder, isDonationTemporarilyHidden { return }
        if donationPanel?.isVisible == true { return }
        hideDonationPanel()

        let width: CGFloat = 360
        let height: CGFloat = 420
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = localized("Support FinderPathBar", "支持 FinderPathBar")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabView)
        panel.contentView = root

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        tabView.addTabViewItem(makeDonationTipTabItem())
        tabView.addTabViewItem(makeDonationPermanentCloseTabItem())

        if self.panel.isVisible {
            let anchor = self.panel.frame
            let x = anchor.midX - width / 2
            let y = max(40, anchor.minY - height - 10)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: visible.midX - width / 2,
                    y: visible.midY - height / 2,
                    width: width,
                    height: height
                ),
                display: true
            )
        }

        donationPanel = panel
        panel.orderFrontRegardless()
        AppLogger.shared.log("donation panel shown reminder=\(triggeredByReminder)")
    }

    private func makeDonationTipTabItem() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "tip")
        item.label = localized("Tip", "扫码赞赏")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 440))
        let qrSize: CGFloat = 180

        let title = NSTextField(labelWithString: localized("Scan to tip", "扫码赞赏支持"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: localized(
            "Thank you for supporting development.",
            "感谢你对 FinderPathBar 的支持。"
        ))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let qrButton = NonActivatingButton(title: "", target: nil, action: nil)
        qrButton.image = donationQRImage()
        qrButton.imagePosition = .imageOnly
        qrButton.imageScaling = .scaleProportionallyUpOrDown
        qrButton.isBordered = false
        qrButton.toolTip = localized("Tip QR code", "赞赏二维码")
        qrButton.translatesAutoresizingMaskIntoConstraints = false
        qrButton.mouseDownHandler = { [weak self] in
            self?.handleDonationQRClicked()
        }

        let closeButton = NonActivatingButton(title: localized("Close", "关闭"), target: nil, action: nil)
        closeButton.bezelStyle = .rounded
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.mouseDownHandler = { [weak self] in
            self?.dismissDonationPanelTemporarily()
        }

        let snoozeButton = NonActivatingButton(title: localized("Show again in 1 day", "1天后出现"), target: nil, action: nil)
        snoozeButton.bezelStyle = .rounded
        snoozeButton.translatesAutoresizingMaskIntoConstraints = false
        snoozeButton.mouseDownHandler = { [weak self] in
            self?.snoozeDonationPanelForOneDay()
        }

        view.addSubview(title)
        view.addSubview(subtitle)
        view.addSubview(qrButton)
        view.addSubview(closeButton)
        view.addSubview(snoozeButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            subtitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            qrButton.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            qrButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            qrButton.widthAnchor.constraint(equalToConstant: qrSize),
            qrButton.heightAnchor.constraint(equalToConstant: qrSize),

            closeButton.topAnchor.constraint(equalTo: qrButton.bottomAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.centerXAnchor, constant: -6),
            closeButton.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),

            snoozeButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            snoozeButton.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 6)
        ])

        item.view = view
        return item
    }

    private func makeDonationPermanentCloseTabItem() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "permanent")
        item.label = localized("Permanent close", "永久关闭")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 340))

        let tip = NSTextField(wrappingLabelWithString: localized(
            "1. Tip first on the Tip tab.\n2. After tipping, tap Permanent Close.",
            "1. 请先在「扫码赞赏」页完成赞赏。\n2. 赞赏完成后，点击永久关闭按钮，即可。"
        ))
        tip.font = .systemFont(ofSize: 13, weight: .medium)
        tip.textColor = .systemRed
        tip.translatesAutoresizingMaskIntoConstraints = false

        let permanentButton = NonActivatingButton(
            title: localized("Permanent close", "永久关闭"),
            target: nil,
            action: nil
        )
        permanentButton.bezelStyle = .rounded
        permanentButton.translatesAutoresizingMaskIntoConstraints = false
        permanentButton.mouseDownHandler = { [weak self] in
            self?.confirmDonationPermanentlyClosed()
        }

        view.addSubview(tip)
        view.addSubview(permanentButton)

        NSLayoutConstraint.activate([
            tip.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            tip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            permanentButton.topAnchor.constraint(equalTo: tip.bottomAnchor, constant: 24),
            permanentButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            permanentButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            permanentButton.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])

        item.view = view
        return item
    }

    /// Honor-system permanent dismiss — just a local tip flag.
    private func confirmDonationPermanentlyClosed() {
        hasDonated = true
        donationHiddenUntil = nil
        donationAwaitingFPPanel = false
        stopDonationReminder()
        hideDonationPanel()
        AppLogger.shared.log("donation permanently closed by user (local tip only)")
        showCloseFailure(localized("Tip closed permanently", "已永久关闭赞赏提示"))
        refocusAttachedFinderWindow(activateFinder: true)
    }

    private func donationQRImage() -> NSImage {
        if let named = NSImage(named: "DonateQR") {
            return named
        }
        if let url = Bundle.main.url(forResource: "DonateQR", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let size = NSSize(width: 180, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let text = localized("Tip QR", "赞赏二维码") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
            withAttributes: attrs
        )
        image.unlockFocus()
        return image
    }

    private func handleDonationQRClicked() {
        donationPanel?.orderFrontRegardless()
        AppLogger.shared.log("donation QR clicked")
    }

    @objc private func dismissDonationPanelTemporarily() {
        hideDonationPanel()
        if !hasDonated, !isDonationTemporarilyHidden {
            scheduleNextDonationReminder(after: 10 * 60)
        }
        refocusAttachedFinderWindow(activateFinder: true)
    }

    private func snoozeDonationPanelForOneDay() {
        let until = Date().addingTimeInterval(24 * 60 * 60)
        donationHiddenUntil = until
        donationAwaitingFPPanel = false
        stopDonationReminder()
        hideDonationPanel()
        scheduleNextDonationReminder(after: until.timeIntervalSinceNow)
        AppLogger.shared.log("donation snoozed until \(until)")
        showCloseFailure(localized("Will show again in 1 day", "已设置 1 天后再次出现"))
        refocusAttachedFinderWindow(activateFinder: true)
    }

    private func hideDonationPanel() {
        if let panel = donationPanel {
            panel.delegate = nil
            panel.orderOut(nil)
        }
        donationPanel = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === donationPanel else { return }
        donationPanel = nil
        guard !hasDonated else { return }
        if isDonationTemporarilyHidden {
            if let until = donationHiddenUntil {
                scheduleNextDonationReminder(after: max(1, until.timeIntervalSinceNow))
            }
            refocusAttachedFinderWindow(activateFinder: true)
            return
        }
        scheduleNextDonationReminder(after: 10 * 60)
        refocusAttachedFinderWindow(activateFinder: true)
    }

    private func openHistoryPath(_ path: String) {
        hideHistoryPanel()
        navigateFinder(to: path, source: "history")
    }

    private func recordHistory(_ path: String) {
        guard !isNavigatingHistory else { return }
        let normalizedPath = normalizePath(path)

        if history.indices.contains(historyIndex), history[historyIndex].path == normalizedPath {
            return
        }

        if historyIndex >= 0, historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }

        if let duplicateIndex = history.firstIndex(where: { $0.path == normalizedPath }) {
            history.remove(at: duplicateIndex)
            if duplicateIndex < historyIndex {
                historyIndex -= 1
            }
        }

        history.append(HistoryEntry(path: normalizedPath, openedAt: Date()))
        if history.count > 100 {
            history.removeFirst()
            historyIndex = max(-1, historyIndex - 1)
        }
        historyIndex = history.count - 1
    }

    private func navigateToHistoryItem(restoring previousHistoryIndex: Int) {
        guard history.indices.contains(historyIndex) else { return }
        let path = normalizePath(history[historyIndex].path)

        // Open/Save dialog: stay in the dialog — never activate Finder via setFinderTarget.
        if isFileDialogMode {
            let dialogExists = findFrontFileDialog() != nil
                || (attachedFileDialogPID.flatMap { NSRunningApplication(processIdentifier: $0) }.flatMap { fileDialog(in: $0) } != nil)
            var isDirectory: ObjCBool = false
            let pathExists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            guard dialogExists, pathExists else {
                historyIndex = previousHistoryIndex
                NSSound.beep()
                updateNavigationButtonStates()
                return
            }
            isNavigatingHistory = true
            ignoreNextSyncRecordUntil = Date().addingTimeInterval(0.5)
            applyPathToUI(path)
            updateBookmarkButton()
            navigateFileDialog(to: path, source: "history-nav")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                self.isNavigatingHistory = false
                self.ignoreNextSyncRecordUntil = Date().addingTimeInterval(0.2)
                self.updateNavigationButtonStates()
            }
            return
        }

        let previousPath = currentFinderPath()
        isNavigatingHistory = true
        ignoreNextSyncRecordUntil = Date().addingTimeInterval(0.4)
        guard setFinderTarget(URL(fileURLWithPath: path)) else {
            historyIndex = previousHistoryIndex
            isNavigatingHistory = false
            NSSound.beep()
            AppLogger.shared.log("navigateToHistoryItem failed path=\(path)")
            updateNavigationButtonStates()
            return
        }
        pathField.stringValue = path
        updateBookmarkButton()
        finishFastFinderNavigation(after: 0.02, selecting: selectionCandidate(from: previousPath, to: path))
    }

    private func finishFastFinderNavigation(after delay: TimeInterval, selecting selectionURL: URL? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lastPathSyncAt = .distantPast
            // Keep sidebar-aligned width stable while Finder is still transitioning.
            self.updatePanelFrame(lightweight: true)
            self.updateHistoryPanelFrame()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.06, delay + 0.04)) { [weak self] in
            guard let self else { return }
            if let currentPath = self.currentFinderPath(), !currentPath.isEmpty {
                self.applyPathToUI(currentPath)
            }
            self.isNavigatingHistory = false
            self.ignoreNextSyncRecordUntil = Date().addingTimeInterval(0.25)
            self.updateNavigationButtonStates()
            // One deferred full refresh after Finder settles.
            self.updatePanelFrame(lightweight: true)
            self.updateHistoryPanelFrame()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.updatePanelFrame()
            }
            if let selectionURL {
                self.revealAndSelectFinderItem(selectionURL)
            }
        }
    }

    private func selectionCandidate(from previousPath: String?, to destinationPath: String) -> URL? {
        guard let previousPath else { return nil }
        let previousURL = URL(fileURLWithPath: normalizePath(previousPath), isDirectory: true)
        let destinationURL = URL(fileURLWithPath: normalizePath(destinationPath), isDirectory: true)
        if previousURL.deletingLastPathComponent().standardizedFileURL.path == destinationURL.standardizedFileURL.path {
            return previousURL
        }
        return nil
    }

    private func activateFinder() {
        runFinderScript("""
        tell application "Finder"
            activate
        end tell
        """)
    }

    private func openFinderWindowIfNeeded() {
        beginFinderWindowTransition()
        runFinderScript("""
        tell application "Finder"
            if (count of Finder windows) = 0 then make new Finder window to home
        end tell
        """)
    }

    @discardableResult
    private func setFinderTarget(_ url: URL) -> Bool {
        setFinderTargetSync(url)
    }

    @discardableResult
    private func setFinderTargetSync(_ url: URL) -> Bool {
        beginFinderWindowTransition()
        let path = normalizePath(url.path)
        guard FileManager.default.fileExists(atPath: path) else {
            AppLogger.shared.log("setFinderTarget missing path=\(path)")
            return false
        }
        // If a poll script is mid-flight, don't treat that as a hard failure.
        if isExecutingAppleScript {
            AppLogger.shared.log("setFinderTarget deferred busy path=\(path)")
            return false
        }
        let script = """
        tell application "Finder"
            set destinationFolder to (POSIX file "\(escapedAppleScript(path))" as alias)
            activate
            if (count of Finder windows) = 0 then
                make new Finder window to destinationFolder
                return "new-window"
            end if

            try
                set target of front Finder window to destinationFolder
                return "target"
            on error
                try
                    open destinationFolder
                    return "open-fallback"
                on error
                    return "failed"
                end try
            end try
        end tell
        """
        guard let result = runFinderScript(script),
              let value = result.stringValue,
              value != "failed" else {
            return false
        }
        if value == "open-fallback" {
            AppLogger.shared.log("setFinderTarget fallback=open path=\(path)")
        }
        return true
    }

    private func selectFinderItem(_ url: URL, after delay: TimeInterval = 0) {
        let path = normalizePath(url.path)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runFinderScriptAsync("""
            tell application "Finder"
                if (count of Finder windows) = 0 then return
                try
                    update front Finder window
                    set theItem to POSIX file "\(escapedAppleScript(path))"
                    reveal theItem
                    select theItem
                end try
            end tell
            """)
        }
    }

    // MARK: - Open / Save file dialog support

    private struct FileDialogInfo {
        let app: NSRunningApplication
        let window: AXUIElement
        let bounds: NSRect
    }

    private func clearFileDialogMode() {
        isFileDialogMode = false
        attachedFileDialogPID = nil
        lastFileDialogBounds = nil
        isNavigatingFileDialog = false
        fileDialogNavigationToken += 1
    }

    /// Drop Open/Save attachment and allow immediate Finder reattach.
    private func leaveFileDialogModeForFinder() {
        guard isFileDialogMode else { return }
        AppLogger.shared.log("leaveFileDialogModeForFinder")
        clearFileDialogMode()
        // Dialog sync repeatedly refreshed suppressAutoHide; clear it so Finder
        // can take the path bar right away.
        suppressAutoHideUntil = nil
        lastFileDialogPathSyncAt = .distantPast
        lastPathSyncAt = .distantPast
        lastFinderWindowBounds = nil
        lastMainContentBounds = nil
        attachedFinderWindowID = nil
    }

    private func enterFileDialogMode(_ dialog: FileDialogInfo) {
        // Never steal the bar from Finder while Finder is frontmost.
        guard !isFinderFrontmost else { return }
        let wasAlready = isFileDialogMode && attachedFileDialogPID == dialog.app.processIdentifier
        isFileDialogMode = true
        attachedFileDialogPID = dialog.app.processIdentifier
        lastFileDialogBounds = dialog.bounds
        attachedFinderWindowID = nil
        manuallyHidden = false
        unregisterHotKeys()
        stopKeyEventTap()
        if !wasAlready {
            AppLogger.shared.log("enterFileDialogMode pid=\(dialog.app.processIdentifier) app=\(dialog.app.bundleIdentifier ?? "?")")
            if let path = currentFileDialogPath(from: dialog) {
                applyPathToUI(path)
                recordHistory(path)
            }
        }
        syncWithFileDialog(dialog)
    }

    private func syncWithFileDialog(_ dialog: FileDialogInfo) {
        guard !isFinderFrontmost else {
            leaveFileDialogModeForFinder()
            return
        }
        lastFileDialogBounds = dialog.bounds
        suppressAutoHide(duration: 0.6)
        guard !manuallyHidden else { return }
        if !panel.isVisible {
            updatePanelFrame()
            panel.orderFrontRegardless()
            startFollowingFinder()
            startMouseMonitor()
        } else {
            updatePanelFrame(lightweight: true)
        }
        updatePanelLevelForCurrentApp()
        let now = Date()
        guard !isEditingPath, !isNavigatingFileDialog,
              now.timeIntervalSince(lastFileDialogPathSyncAt) >= 0.35 else {
            return
        }
        lastFileDialogPathSyncAt = now
        if let path = currentFileDialogPath(from: dialog), !path.isEmpty {
            if path != normalizePath(pathField.stringValue) {
                applyPathToUI(path)
            }
            recordHistory(path)
        }
        updateBookmarkButton()
        updateNavigationButtonStates()
    }

    private func defaultFileDialogPanelFrame() -> NSRect? {
        let windowFrame = lastFileDialogBounds
            ?? findFrontFileDialog()?.bounds
        guard let windowFrame, windowFrame.width > 40 else { return nil }
        let height = currentPanelHeight(forWidth: windowFrame.width)
        // Sit above the dialog so the native title bar (traffic lights / folder name)
        // stays visible — same vertical pinning as Finder windows.
        return NSRect(
            x: windowFrame.minX,
            y: windowFrame.maxY + verticalGap,
            width: windowFrame.width,
            height: height
        )
    }

    private func findFrontFileDialog() -> FileDialogInfo? {
        guard ensureAccessibilityPermission(prompt: false),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.apple.finder",
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            // When FP itself is frontmost (user clicked the bar), keep using the
            // previously attached dialog host if it still has an open panel.
            if isFinderPathBarFrontmost, let pid = attachedFileDialogPID,
               let app = NSRunningApplication(processIdentifier: pid),
               let dialog = fileDialog(in: app) {
                return dialog
            }
            return nil
        }
        return fileDialog(in: app)
    }

    private func fileDialog(in app: NSRunningApplication) -> FileDialogInfo? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var candidates: [AXUIElement] = []

        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focused = AXSafe.element(focusedValue) {
            candidates.append(focused)
            candidates.append(contentsOf: axSheets(in: focused))
        }

        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for window in windows {
                candidates.append(window)
                candidates.append(contentsOf: axSheets(in: window))
            }
        }

        var seenHashes = Set<UInt>()
        for candidate in candidates {
            let hash = UInt(CFHash(candidate))
            guard seenHashes.insert(hash).inserted else { continue }
            guard looksLikeFileDialog(candidate),
                  let bounds = axWindowRect(candidate),
                  bounds.width >= 320, bounds.height >= 220 else {
                continue
            }
            return FileDialogInfo(app: app, window: candidate, bounds: bounds)
        }
        return nil
    }

    private func axSheets(in window: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children.filter { element in
            axRole(element) == "AXSheet" || axSubrole(element) == "AXDialog"
        }
    }

    private func looksLikeFileDialog(_ element: AXUIElement) -> Bool {
        let titles = collectButtonTitles(in: element, limit: 40)
        guard !titles.isEmpty else { return false }
        let normalized = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasCancel = normalized.contains { $0 == "cancel" || $0 == "取消" }
        let hasConfirm = normalized.contains {
            $0 == "open" || $0 == "打开" || $0 == "save" || $0 == "存储" || $0 == "储存"
                || $0 == "choose" || $0 == "选择" || $0 == "select" || $0 == "上传"
                || $0.hasPrefix("open ") || $0.hasPrefix("打开")
        }
        guard hasCancel && hasConfirm else { return false }
        // Prefer dialogs that also look like a browser (list / outline / search).
        if containsFileBrowserChrome(element) {
            return true
        }
        // Some sandboxed panels expose fewer roles; Cancel+Open is enough.
        let role = axRole(element)
        return role == "AXSheet" || role == "AXWindow" || axSubrole(element) == "AXDialog"
    }

    private func containsFileBrowserChrome(_ element: AXUIElement) -> Bool {
        var found = false
        walkAX(element, maxNodes: 80) { child in
            let role = axRole(child)
            if role == "AXOutline" || role == "AXTable" || role == "AXBrowser"
                || role == "AXScrollArea" || role == "AXSplitGroup"
                || role == "AXSearchField" {
                found = true
                return false
            }
            return true
        }
        return found
    }

    private func collectButtonTitles(in root: AXUIElement, limit: Int) -> [String] {
        var titles: [String] = []
        walkAX(root, maxNodes: 120) { element in
            if titles.count >= limit { return false }
            if axRole(element) == "AXButton", let title = axTitle(element), !title.isEmpty {
                titles.append(title)
            }
            return true
        }
        return titles
    }

    private func currentFileDialogPath(from dialog: FileDialogInfo) -> String? {
        if let document = axStringAttribute(dialog.window, kAXDocumentAttribute as String)
            ?? axStringAttribute(dialog.window, kAXURLAttribute as String) {
            let path = normalizePath(document.replacingOccurrences(of: "file://", with: ""))
            if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        if let path = pathFromAXPathControl(in: dialog.window) {
            return path
        }
        if let path = pathLikeString(in: dialog.window) {
            return path
        }
        // Fall back: keep showing whatever we already have if still valid.
        let current = normalizePath(pathField.stringValue)
        if !current.isEmpty, FileManager.default.fileExists(atPath: current) {
            return current
        }
        return nil
    }

    private func pathFromAXPathControl(in root: AXUIElement) -> String? {
        var components: [String] = []
        walkAX(root, maxNodes: 100) { element in
            let role = axRole(element)
            if role == "AXPath" || role == "AXList" {
                // Continue into children for path segments.
            }
            if role == "AXButton" || role == "AXStaticText" || role == "AXMenuButton" {
                if let title = axTitle(element) ?? axStringAttribute(element, kAXValueAttribute as String) {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Path controls often use folder names; joining alone is ambiguous.
                    // Prefer an explicit POSIX path value when present.
                    if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
                        components = [trimmed]
                        return false
                    }
                }
            }
            if let value = axStringAttribute(element, kAXValueAttribute as String) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
                    components = [trimmed]
                    return false
                }
                if trimmed.hasPrefix("~") {
                    let expanded = (trimmed as NSString).expandingTildeInPath
                    if FileManager.default.fileExists(atPath: expanded) {
                        components = [expanded]
                        return false
                    }
                }
            }
            return true
        }
        guard let only = components.first else { return nil }
        return normalizePath(only)
    }

    private func pathLikeString(in root: AXUIElement) -> String? {
        var best: String?
        walkAX(root, maxNodes: 100) { element in
            guard let value = axStringAttribute(element, kAXValueAttribute as String)
                    ?? axTitle(element) else {
                return true
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate: String
            if trimmed.hasPrefix("~") {
                candidate = (trimmed as NSString).expandingTildeInPath
            } else {
                candidate = trimmed
            }
            guard candidate.hasPrefix("/"),
                  candidate.count > 1,
                  !candidate.contains("\n"),
                  FileManager.default.fileExists(atPath: candidate) else {
                return true
            }
            if best == nil || candidate.count > (best?.count ?? 0) {
                best = candidate
            }
            return true
        }
        return best.map(normalizePath)
    }

    /// Parent folder in Open/Save panels: use ⌘↑ only (never Open / ⌘↓).
    private func navigateFileDialogToParent(from currentURL: URL, to parentURL: URL) {
        navigateFileDialog(to: parentURL.path, source: "parent")
    }

    private func focusFileDialogBrowser(in dialog: FileDialogInfo) {
        var browser: AXUIElement?
        walkAX(dialog.window, maxNodes: 120) { element in
            let role = axRole(element)
            if role == "AXOutline" || role == "AXBrowser" || role == "AXTable" {
                browser = element
                return false
            }
            return true
        }
        if browser == nil {
            walkAX(dialog.window, maxNodes: 80) { element in
                if axRole(element) == "AXScrollArea" {
                    browser = element
                    return false
                }
                return true
            }
        }
        if let browser {
            AXUIElementSetAttributeValue(browser, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(browser, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(dialog.window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(dialog.window, kAXRaiseAction as CFString)
    }

    private func navigateFileDialog(to rawPath: String, source: String) {
        let normalizedPath = normalizePath((rawPath as NSString).expandingTildeInPath)
        AppLogger.shared.log("navigateFileDialog path=\(normalizedPath) source=\(source)")
        guard !normalizedPath.isEmpty else {
            NSSound.beep()
            return
        }
        var isDirectory: ObjCBool = false
        var targetPath = normalizedPath
        if FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                targetPath = URL(fileURLWithPath: normalizedPath).deletingLastPathComponent().path
            }
        } else {
            NSSound.beep()
            showCloseFailure(localized("Path no longer exists", "路径不存在"))
            return
        }
        targetPath = normalizePath(targetPath)

        guard let dialog = findFrontFileDialog()
                ?? (attachedFileDialogPID.flatMap { NSRunningApplication(processIdentifier: $0) }.flatMap { fileDialog(in: $0) }) else {
            NSSound.beep()
            showCloseFailure(localized("No file dialog", "未找到打开/保存对话框"))
            clearFileDialogMode()
            return
        }

        var fromPath = normalizePath(pathField.stringValue)
        if let live = currentFileDialogPath(from: dialog), !live.isEmpty {
            fromPath = live
        }

        let fromURL = URL(fileURLWithPath: fromPath.isEmpty ? targetPath : fromPath, isDirectory: true).standardizedFileURL
        let toURL = URL(fileURLWithPath: targetPath, isDirectory: true).standardizedFileURL
        if fromURL.path == toURL.path {
            applyPathToUI(targetPath)
            return
        }

        let plan = fileDialogRelativePlan(from: fromURL, to: toURL)
        AppLogger.shared.log(
            "navigateFileDialog source=\(source) up=\(plan.upCount) down=\(plan.downNames.count) from=\(fromURL.path) to=\(toURL.path)"
        )

        // Parent / ancestor: ⌘↑ only (same as the 「上级」 button).
        // Bookmarks / history / address: ⌘↑ to common ancestor, then enter each
        // child folder by double-click (never ⌘↓/Open — that closes the panel).
        // ⌘⇧G only if a down step cannot be verified.
        if plan.downNames.isEmpty, plan.upCount > 0 {
            navigateFileDialogByParentSteps(plan.upCount, targetPath: targetPath, dialog: dialog)
        } else {
            navigateFileDialogRelatively(plan: plan, fromPath: fromURL.path, targetPath: targetPath, dialog: dialog)
        }
    }

    private struct FileDialogRelativePlan {
        let upCount: Int
        let downNames: [String]
    }

    private func fileDialogRelativePlan(from fromURL: URL, to toURL: URL) -> FileDialogRelativePlan {
        let fromParts = fromURL.pathComponents
        let toParts = toURL.pathComponents
        var common = 0
        while common < fromParts.count, common < toParts.count, fromParts[common] == toParts[common] {
            common += 1
        }
        let upCount = max(0, fromParts.count - common)
        let downNames = Array(toParts[common...]).filter { $0 != "/" && !$0.isEmpty }
        return FileDialogRelativePlan(upCount: upCount, downNames: downNames)
    }

    private func navigateFileDialogByParentSteps(_ steps: Int, targetPath: String, dialog: FileDialogInfo) {
        guard steps > 0 else {
            finishFileDialogNavigation(to: targetPath)
            return
        }
        fileDialogNavigationToken += 1
        let token = fileDialogNavigationToken
        isNavigatingFileDialog = true
        suppressAutoHide(duration: max(1.0, 0.12 * Double(steps) + 0.6))
        applyPathToUI(targetPath)
        dialog.app.activate(options: [.activateIgnoringOtherApps])
        focusFileDialogBrowser(in: dialog)

        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 + 0.08 * Double(i)) { [weak self] in
                guard let self, self.fileDialogNavigationToken == token else { return }
                self.focusFileDialogBrowser(in: self.latestFileDialog(fallback: dialog) ?? dialog)
                self.postKeyCombo(keyCode: CGKeyCode(kVK_UpArrow), flags: [.maskCommand])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + 0.08 * Double(steps)) { [weak self] in
            guard let self, self.fileDialogNavigationToken == token else { return }
            self.finishFileDialogNavigation(to: targetPath)
        }
    }

    /// Bookmark-style jumps without ⌘⇧G when possible: ups + double-click into folders.
    private func navigateFileDialogRelatively(
        plan: FileDialogRelativePlan,
        fromPath: String,
        targetPath: String,
        dialog: FileDialogInfo
    ) {
        fileDialogNavigationToken += 1
        let token = fileDialogNavigationToken
        isNavigatingFileDialog = true
        let stepCount = plan.upCount + plan.downNames.count
        suppressAutoHide(duration: max(1.8, 0.22 * Double(stepCount) + 1.0))
        applyPathToUI(targetPath)
        dialog.app.activate(options: [.activateIgnoringOtherApps])
        focusFileDialogBrowser(in: dialog)

        runFileDialogRelativeStep(
            plan: plan,
            targetPath: targetPath,
            dialog: dialog,
            token: token,
            stepIndex: 0,
            expectedPath: normalizePath(fromPath)
        )
    }

    private func runFileDialogRelativeStep(
        plan: FileDialogRelativePlan,
        targetPath: String,
        dialog: FileDialogInfo,
        token: Int,
        stepIndex: Int,
        expectedPath: String
    ) {
        guard fileDialogNavigationToken == token else { return }

        if stepIndex < plan.upCount {
            let liveDialog = latestFileDialog(fallback: dialog) ?? dialog
            focusFileDialogBrowser(in: liveDialog)
            postKeyCombo(keyCode: CGKeyCode(kVK_UpArrow), flags: [.maskCommand])
            let nextExpected = URL(fileURLWithPath: expectedPath, isDirectory: true)
                .deletingLastPathComponent()
                .standardizedFileURL.path
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.runFileDialogRelativeStep(
                    plan: plan,
                    targetPath: targetPath,
                    dialog: liveDialog,
                    token: token,
                    stepIndex: stepIndex + 1,
                    expectedPath: self?.normalizePath(nextExpected) ?? nextExpected
                )
            }
            return
        }

        let downIndex = stepIndex - plan.upCount
        if downIndex < plan.downNames.count {
            let name = plan.downNames[downIndex]
            let liveDialog = latestFileDialog(fallback: dialog) ?? dialog
            let nextExpected = normalizePath(
                (expectedPath as NSString).appendingPathComponent(name)
            )

            // Prefer Places sidebar for well-known destinations (no Open / no GTG).
            if clickFileDialogSidebarItem(named: name, in: liveDialog) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    guard let self, self.fileDialogNavigationToken == token else { return }
                    self.verifyOrContinueFileDialogDown(
                        plan: plan,
                        targetPath: targetPath,
                        dialog: liveDialog,
                        token: token,
                        stepIndex: stepIndex + 1,
                        expectedPath: nextExpected
                    )
                }
                return
            }

            focusFileDialogBrowser(in: liveDialog)
            let entered = enterFileDialogChildFolder(named: name, parentPath: expectedPath, in: liveDialog)
            if !entered {
                AppLogger.shared.log("relative down missing folder=\(name); fallback GoToFolder")
                navigateFileDialogViaGoToFolder(targetPath: targetPath, dialog: liveDialog)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.fileDialogNavigationToken == token else { return }
                self.verifyOrContinueFileDialogDown(
                    plan: plan,
                    targetPath: targetPath,
                    dialog: liveDialog,
                    token: token,
                    stepIndex: stepIndex + 1,
                    expectedPath: nextExpected
                )
            }
            return
        }

        finishFileDialogNavigation(to: targetPath)
    }

    private func verifyOrContinueFileDialogDown(
        plan: FileDialogRelativePlan,
        targetPath: String,
        dialog: FileDialogInfo,
        token: Int,
        stepIndex: Int,
        expectedPath: String
    ) {
        guard fileDialogNavigationToken == token else { return }
        let liveDialog = latestFileDialog(fallback: dialog) ?? dialog
        let live = currentFileDialogPath(from: liveDialog).map(normalizePath)
        let expected = normalizePath(expectedPath)
        if let live, live != expected {
            // Allow brief lag: if still under expected parent, wait once more.
            let parent = URL(fileURLWithPath: expected, isDirectory: true)
                .deletingLastPathComponent().path
            if normalizePath(live) == normalizePath(parent) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.fileDialogNavigationToken == token else { return }
                    let again = self.currentFileDialogPath(from: self.latestFileDialog(fallback: liveDialog) ?? liveDialog)
                        .map(self.normalizePath)
                    if again == expected {
                        self.runFileDialogRelativeStep(
                            plan: plan,
                            targetPath: targetPath,
                            dialog: liveDialog,
                            token: token,
                            stepIndex: stepIndex,
                            expectedPath: expected
                        )
                    } else {
                        AppLogger.shared.log("relative verify failed live=\(again ?? "nil") expected=\(expected); GoToFolder")
                        self.navigateFileDialogViaGoToFolder(targetPath: targetPath, dialog: liveDialog)
                    }
                }
                return
            }
            AppLogger.shared.log("relative verify failed live=\(live) expected=\(expected); GoToFolder")
            navigateFileDialogViaGoToFolder(targetPath: targetPath, dialog: liveDialog)
            return
        }
        runFileDialogRelativeStep(
            plan: plan,
            targetPath: targetPath,
            dialog: liveDialog,
            token: token,
            stepIndex: stepIndex,
            expectedPath: expected
        )
    }

    /// Enter a child folder via select + double-click (not ⌘↓/Open).
    @discardableResult
    private func enterFileDialogChildFolder(named name: String, parentPath: String, in dialog: FileDialogInfo) -> Bool {
        let aliases = fileDialogNameAliases(posixName: name, parentPath: parentPath)
        guard let row = findFileDialogRow(namedAnyOf: aliases, in: dialog.window) else {
            AppLogger.shared.log("enterFileDialogChildFolder no row name=\(name)")
            return false
        }

        AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        if let parentOutline = axParentMatching(row, roles: ["AXOutline", "AXTable", "AXList", "AXBrowser"]) {
            AXUIElementSetAttributeValue(parentOutline, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let selected = [row] as CFArray
            AXUIElementSetAttributeValue(parentOutline, kAXSelectedRowsAttribute as CFString, selected)
            AXUIElementSetAttributeValue(parentOutline, kAXSelectedChildrenAttribute as CFString, selected)
        }

        // Double-click enters a folder in Open/Save panels without confirming Open.
        if doubleClickAXElement(row) {
            return true
        }
        // Column view: Right Arrow drills into the selected folder.
        postKeyCombo(keyCode: CGKeyCode(kVK_RightArrow), flags: [])
        return true
    }

    private func fileDialogNameAliases(posixName: String, parentPath: String) -> [String] {
        var names: [String] = []
        let trimmed = posixName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { names.append(trimmed) }
        let full = (parentPath as NSString).appendingPathComponent(posixName)
        let display = FileManager.default.displayName(atPath: full)
        if !display.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(display) == .orderedSame }) {
            names.append(display)
        }
        return names
    }

    @discardableResult
    private func clickFileDialogSidebarItem(named name: String, in dialog: FileDialogInfo) -> Bool {
        let aliases = fileDialogNameAliases(posixName: name, parentPath: "/")
        let placeHints: Set<String> = [
            "desktop", "documents", "downloads", "movies", "music", "pictures",
            "applications", "utilities", "home", "icloud drive", "icloud",
            "airdrop", "recents", "recent", "shared", "network", "volumes",
            "macintosh hd", "users",
            "桌面", "文稿", "下载", "影片", "音乐", "图片", "应用程序", "实用工具",
            "个人收藏", "最近使用", "最近项目", "iCloud 云盘"
        ]
        let isLikelyPlace = aliases.contains { placeHints.contains($0.lowercased()) }
            || aliases.contains { placeHints.contains($0) }
        guard isLikelyPlace else { return false }

        var match: AXUIElement?
        walkAX(dialog.window, maxNodes: 220) { element in
            let role = axRole(element)
            guard role == "AXStaticText" || role == "AXButton" || role == "AXCell" || role == "AXRow" else {
                return true
            }
            guard let title = fileDialogElementTitle(element) else { return true }
            guard aliases.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) else {
                return true
            }
            if let frame = axWindowRect(element), frame.minX < 220, frame.width < 280 {
                match = element
                return false
            }
            if match == nil { match = element }
            return true
        }
        guard let match else { return false }
        let pressTarget = axParentMatching(match, roles: ["AXRow", "AXButton", "AXCell"]) ?? match
        let ok = AXUIElementPerformAction(pressTarget, kAXPressAction as CFString) == .success
        AppLogger.shared.log("clickFileDialogSidebarItem name=\(name) ok=\(ok)")
        return ok
    }

    private func findFileDialogRow(namedAnyOf names: [String], in root: AXUIElement) -> AXUIElement? {
        let wanted = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return nil }

        var listRoots: [AXUIElement] = []
        walkAX(root, maxNodes: 160) { element in
            let role = axRole(element)
            if role == "AXOutline" || role == "AXBrowser" || role == "AXTable" {
                if let frame = axWindowRect(element), frame.width >= 200 {
                    listRoots.append(element)
                }
            }
            return true
        }
        let searchRoots = listRoots.isEmpty ? [root] : listRoots

        for searchRoot in searchRoots {
            var match: AXUIElement?
            walkAX(searchRoot, maxNodes: 280) { element in
                let role = axRole(element)
                if role == "AXRow" {
                    if let title = fileDialogElementTitle(element),
                       wanted.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) {
                        match = element
                        return false
                    }
                }
                if role == "AXStaticText" || role == "AXCell" {
                    if let title = fileDialogElementTitle(element),
                       wanted.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) {
                        match = axParentMatching(element, roles: ["AXRow"]) ?? element
                        return false
                    }
                }
                return true
            }
            if let match { return match }
        }
        return nil
    }

    private func fileDialogElementTitle(_ element: AXUIElement) -> String? {
        if let title = axTitle(element)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let value = axStringAttribute(element, kAXValueAttribute as String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let title = fileDialogElementTitle(child), !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private func axParentMatching(_ element: AXUIElement, roles: [String]) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let node = current else { return nil }
            if roles.contains(axRole(node)) {
                return node
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = AXSafe.element(parentValue) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    @discardableResult
    private func doubleClickAXElement(_ element: AXUIElement) -> Bool {
        guard let quartz = axElementScreenRect(element) else { return false }
        let point = CGPoint(x: quartz.midX, y: quartz.midY)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        move.post(tap: .cghidEventTap)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if let down2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
           let up2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            down2.setIntegerValueField(.mouseEventClickState, value: 2)
            up2.setIntegerValueField(.mouseEventClickState, value: 2)
            down2.post(tap: .cghidEventTap)
            up2.post(tap: .cghidEventTap)
        }
        return true
    }

    private func latestFileDialog(fallback: FileDialogInfo) -> FileDialogInfo? {
        findFrontFileDialog()
            ?? (attachedFileDialogPID.flatMap { NSRunningApplication(processIdentifier: $0) }.flatMap { fileDialog(in: $0) })
            ?? fallback
    }

    private func finishFileDialogNavigation(to targetPath: String) {
        isNavigatingFileDialog = false
        recordHistory(targetPath)
        applyPathToUI(targetPath)
        if let refreshed = findFrontFileDialog() {
            syncWithFileDialog(refreshed)
        }
    }

    /// Fallback only: ⌘⇧G once. Move the sheet off-screen; confirm with the Go button (not bare Return/Open).
    private func navigateFileDialogViaGoToFolder(targetPath: String, dialog: FileDialogInfo) {
        AppLogger.shared.log("navigateFileDialogViaGoToFolder path=\(targetPath)")
        fileDialogNavigationToken += 1
        let token = fileDialogNavigationToken
        isNavigatingFileDialog = true
        suppressAutoHide(duration: 2.0)
        applyPathToUI(targetPath)
        dialog.app.activate(options: [.activateIgnoringOtherApps])
        focusFileDialogBrowser(in: dialog)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.fileDialogNavigationToken == token else { return }
            self.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_G), flags: [.maskCommand, .maskShift])
            self.completeGoToFolderOffscreen(app: dialog.app, path: targetPath, token: token, attempt: 0)
        }
    }

    private func completeGoToFolderOffscreen(app: NSRunningApplication, path: String, token: Int, attempt: Int) {
        guard fileDialogNavigationToken == token else { return }
        if let sheet = findGoToFolderSheet(in: app) {
            moveAXElementOffscreen(sheet.sheet)
            AXUIElementSetAttributeValue(sheet.field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let setOK = AXUIElementSetAttributeValue(sheet.field, kAXValueAttribute as CFString, path as CFTypeRef) == .success
            if !setOK {
                typeTextViaClipboard(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.confirmGoToFolderAndFinish(app: app, path: path, token: token)
                }
            } else {
                confirmGoToFolderAndFinish(app: app, path: path, token: token)
            }
            return
        }
        if attempt < 24 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.completeGoToFolderOffscreen(app: app, path: path, token: token, attempt: attempt + 1)
            }
            return
        }
        AppLogger.shared.log("goToFolder sheet not found; abort without Return (avoids closing Open dialog)")
        isNavigatingFileDialog = false
        NSSound.beep()
        showCloseFailure(localized("Couldn't jump in file dialog", "无法在打开对话框中跳转"))
    }

    private func confirmGoToFolderAndFinish(app: NSRunningApplication, path: String, token: Int) {
        guard fileDialogNavigationToken == token else { return }
        // Prefer pressing the sheet's Go/前往 button. Bare Return can hit Open and close the panel.
        if let sheet = findGoToFolderSheet(in: app) {
            moveAXElementOffscreen(sheet.sheet)
            if pressGoToFolderConfirmButton(in: sheet.sheet) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                    guard let self, self.fileDialogNavigationToken == token else { return }
                    self.finishFileDialogNavigation(to: path)
                }
                return
            }
            AXUIElementSetAttributeValue(sheet.field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        postKeyCombo(keyCode: CGKeyCode(kVK_Return), flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self, self.fileDialogNavigationToken == token else { return }
            self.finishFileDialogNavigation(to: path)
        }
    }

    @discardableResult
    private func pressGoToFolderConfirmButton(in sheet: AXUIElement) -> Bool {
        var goButton: AXUIElement?
        walkAX(sheet, maxNodes: 50) { element in
            guard axRole(element) == "AXButton" else { return true }
            let title = (axTitle(element) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if title == "go" || title == "前往" || title == "ok" || title == "好" {
                goButton = element
                return false
            }
            return true
        }
        guard let goButton else { return false }
        return AXUIElementPerformAction(goButton, kAXPressAction as CFString) == .success
    }

    private func findGoToFolderSheet(in app: NSRunningApplication) -> (sheet: AXUIElement, field: AXUIElement)? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedUI: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedUI) == .success,
           let focused = AXSafe.element(focusedUI),
           axRole(focused) == "AXTextField" || axRole(focused) == "AXComboBox" {
            if let sheet = axEnclosingSheetOrWindow(focused), isLikelyGoToFolderSheet(sheet) {
                return (sheet, focused)
            }
        }

        var windowsValue: CFTypeRef?
        var candidates: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AXUIElement] {
            for window in windows {
                candidates.append(window)
                candidates.append(contentsOf: axSheets(in: window))
            }
        }
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let focused = AXSafe.element(focusedWindow) {
            candidates.insert(focused, at: 0)
            candidates.append(contentsOf: axSheets(in: focused))
        }

        for candidate in candidates where isLikelyGoToFolderSheet(candidate) {
            var field: AXUIElement?
            walkAX(candidate, maxNodes: 40) { element in
                let role = axRole(element)
                if role == "AXTextField" || role == "AXComboBox" {
                    field = element
                    return false
                }
                return true
            }
            if let field {
                return (candidate, field)
            }
        }
        return nil
    }

    private func isLikelyGoToFolderSheet(_ element: AXUIElement) -> Bool {
        let role = axRole(element)
        let subrole = axSubrole(element)
        let isSheetLike = role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog"
        // Go-to-folder is a small sheet; open panels are large.
        let bounds = axWindowRect(element) ?? .zero
        let compact = bounds.width > 0 && bounds.width < 720 && bounds.height > 0 && bounds.height < 420
        if !(isSheetLike || compact) { return false }

        let titles = collectButtonTitles(in: element, limit: 20)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if titles.contains(where: { $0 == "go" || $0 == "前往" }) {
            return true
        }
        // Cancel + text field is typical; exclude the main Open/Save panel.
        let hasCancel = titles.contains { $0 == "cancel" || $0 == "取消" }
        let hasOpen = titles.contains { $0 == "open" || $0 == "打开" || $0 == "save" || $0 == "存储" }
        if hasOpen { return false }
        var hasField = false
        walkAX(element, maxNodes: 30) { child in
            let role = axRole(child)
            if role == "AXTextField" || role == "AXComboBox" {
                hasField = true
                return false
            }
            return true
        }
        return hasField && (hasCancel || isSheetLike || compact)
    }

    private func axEnclosingSheetOrWindow(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current else { return nil }
            let role = axRole(node)
            let subrole = axSubrole(node)
            if role == "AXSheet" || role == "AXWindow" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                return node
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = AXSafe.element(parentValue) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private func moveAXElementOffscreen(_ element: AXUIElement) {
        var point = CGPoint(x: -20_000, y: -20_000)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func fillGoToFolderField(in app: NSRunningApplication, path: String) -> Bool {
        if let sheet = findGoToFolderSheet(in: app) {
            moveAXElementOffscreen(sheet.sheet)
            AXUIElementSetAttributeValue(sheet.field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return AXUIElementSetAttributeValue(sheet.field, kAXValueAttribute as CFString, path as CFTypeRef) == .success
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var field: AXUIElement?
        var focusedUI: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedUI) == .success,
           let focused = AXSafe.element(focusedUI),
           axRole(focused) == "AXTextField" || axRole(focused) == "AXComboBox" {
            field = focused
        }
        if field == nil, let dialog = fileDialog(in: app) {
            walkAX(dialog.window, maxNodes: 80) { element in
                let role = axRole(element)
                if role == "AXTextField" || role == "AXComboBox" {
                    field = element
                    return false
                }
                return true
            }
        }
        guard let field else { return false }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path as CFTypeRef) == .success
    }

    private func typeTextViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_A), flags: [.maskCommand])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_V), flags: [.maskCommand])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let previous {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    private func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func walkAX(_ root: AXUIElement, maxNodes: Int, visit: (AXUIElement) -> Bool) {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            guard visit(element) else { return }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else {
                continue
            }
            queue.append(contentsOf: children)
        }
    }

    private func axRole(_ element: AXUIElement) -> String {
        axStringAttribute(element, kAXRoleAttribute as String) ?? ""
    }

    private func axSubrole(_ element: AXUIElement) -> String {
        axStringAttribute(element, kAXSubroleAttribute as String) ?? ""
    }

    private func axTitle(_ element: AXUIElement) -> String? {
        axStringAttribute(element, kAXTitleAttribute as String)
    }

    private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.path
        }
        return nil
    }

    private func closeFrontFinderWindowWithAccessibility() -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focused = AXSafe.element(focusedValue) {
            return pressCloseButton(in: focused)
        }

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let firstWindow = windows.first else {
            return false
        }
        return pressCloseButton(in: firstWindow)
    }

    private func closeAttachedFinderWindowWithAccessibility() -> CloseResult {
        guard ensureAccessibilityPermission(prompt: false) else {
            return CloseResult(false, localized("Accessibility permission is not enabled", "辅助功能权限未生效"))
        }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return CloseResult(false, "找不到 Finder 进程")
        }

        if let frontWindow = frontFinderWindowElement(for: finder) {
            return pressCloseButton(in: frontWindow)
                ? CloseResult(true, "")
                : CloseResult(false, "无法按下 Finder 关闭按钮")
        }

        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let firstWindow = windows.first else {
            return CloseResult(false, "无法读取 Finder 窗口")
        }
        return pressCloseButton(in: firstWindow)
            ? CloseResult(true, "")
            : CloseResult(false, "无法按下 Finder 关闭按钮")
    }

    private func closeAttachedFileDialogWithAccessibility() -> CloseResult {
        guard ensureAccessibilityPermission(prompt: false) else {
            return CloseResult(false, localized("Accessibility permission is not enabled", "辅助功能权限未生效"))
        }
        guard let dialog = findFrontFileDialog()
                ?? (attachedFileDialogPID.flatMap { NSRunningApplication(processIdentifier: $0) }.flatMap { fileDialog(in: $0) }) else {
            return CloseResult(false, localized("No file dialog", "未找到打开/保存对话框"))
        }

        AppLogger.shared.log("closeAttachedFileDialog app=\(dialog.app.bundleIdentifier ?? "?")")
        dialog.app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(dialog.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(dialog.window, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        let closed = pressCloseButton(in: dialog.window)
            || pressFileDialogCancelButton(in: dialog.window)
        if !closed {
            postKeyCombo(keyCode: CGKeyCode(kVK_Escape), flags: [])
        }
        clearFileDialogMode()
        return CloseResult(true, "")
    }

    @discardableResult
    private func pressFileDialogCancelButton(in root: AXUIElement) -> Bool {
        var cancelButton: AXUIElement?
        walkAX(root, maxNodes: 80) { element in
            guard axRole(element) == "AXButton" else { return true }
            let title = (axTitle(element) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if title == "cancel" || title == "取消" {
                cancelButton = element
                return false
            }
            return true
        }
        guard let cancelButton else { return false }
        return AXUIElementPerformAction(cancelButton, kAXPressAction as CFString) == .success
    }

    private func attachedFinderWindowElement(for finder: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        if let attachedFinderWindowID,
           let matchedWindow = windows.first(where: { axWindowNumber($0) == attachedFinderWindowID }) {
            return matchedWindow
        }

        if let frontWindow = frontFinderWindowElement(for: finder) {
            return frontWindow
        }

        guard shouldUseFinderWindowContext else {
            return nil
        }

        let panelFrame = panel.frame
        let targetRect = NSRect(
            x: panelFrame.minX - horizontalInset,
            y: panelFrame.minY,
            width: panelFrame.width + horizontalInset * 2,
            height: 0
        )
        return windows
            .compactMap { window -> (AXUIElement, CGFloat)? in
                guard let rect = axWindowRect(window) else { return nil }
                let score = abs(rect.minX - targetRect.minX)
                    + abs(rect.maxY - targetRect.minY)
                    + abs(rect.width - targetRect.width)
                return (window, score)
            }
            .filter { $0.1 <= 400 }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func axWindowNumber(_ window: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success,
              let value else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func refocusAttachedFinderWindow(activateFinder: Bool = false) {
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let window = attachedFinderWindowElement(for: finder) else {
            return
        }

        if activateFinder {
            finder.activate(options: [.activateIgnoringOtherApps])
        }
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func axWindowRect(_ window: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard let position = AXSafe.axValue(positionValue),
              let sizeAX = AXSafe.axValue(sizeValue),
              AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }

        guard let screen = NSScreen.main else {
            return nil
        }
        let appKitY = screen.frame.maxY - point.y - size.height
        return NSRect(x: point.x, y: appKitY, width: size.width, height: size.height)
    }

    private func pressCloseButton(in window: AXUIElement) -> Bool {
        var buttonValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue) == .success,
           let button = AXSafe.element(buttonValue),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            return true
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return false
        }
        for child in children {
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String,
               role == "AXButton",
               AXUIElementPerformAction(child, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return false
    }

    private func axElementScreenRect(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard let position = AXSafe.axValue(positionValue),
              let sizeValueAX = AXSafe.axValue(sizeValue),
              AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(sizeValueAX, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    private func runFinderScript(_ source: String) -> NSAppleEventDescriptor? {
        guard Thread.isMainThread else {
            // Refuse off-main calls entirely. A semaphore+main.async wait can still
            // deadlock when AppleScript has nested the main run loop.
            AppLogger.shared.log("runFinderScript refused off-main-thread call")
            return nil
        }
        guard !isExecutingAppleScript else {
            // Expected: follow-timer / path sync can nest while NSAppleScript
            // re-enters the run loop. Skip quietly; poll again on the next tick.
            reentrantAppleScriptSkipCount += 1
            let now = Date()
            if now.timeIntervalSince(lastReentrantAppleScriptLogAt) > 30 {
                lastReentrantAppleScriptLogAt = now
                AppLogger.shared.log(
                    "runFinderScript coalesced \(reentrantAppleScriptSkipCount) reentrant poll(s) (normal while syncing Finder)"
                )
                reentrantAppleScriptSkipCount = 0
            }
            return nil
        }
        isExecutingAppleScript = true
        defer {
            isExecutingAppleScript = false
            scheduleDeferredAppleScripts()
        }
        let execution = executeAppleScript(source)
        let result = execution.result
        if let error = execution.error {
            logAppleScriptError(error, context: "runFinderScript")
        }
        return result
    }

    private func runFinderScriptAsync(_ source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isExecutingAppleScript {
                self.deferredAppleScripts.append(source)
                return
            }
            _ = self.runFinderScript(source)
        }
    }

    private func scheduleDeferredAppleScripts() {
        guard !deferredAppleScripts.isEmpty else { return }
        let scripts = deferredAppleScripts
        deferredAppleScripts.removeAll()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for source in scripts {
                self.runFinderScriptAsync(source)
            }
        }
    }

    private func executeAppleScript(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (result, error)
    }

    private func logAppleScriptError(_ error: NSDictionary, context: String) {
        let number = error["NSAppleScriptErrorNumber"].map { String(describing: $0) } ?? "unknown"
        let message = (error["NSAppleScriptErrorBriefMessage"] as? String)
            ?? (error["NSAppleScriptErrorMessage"] as? String)
            ?? "unknown error"
        let appName = (error["NSAppleScriptErrorAppName"] as? String).map { " app=\($0)" } ?? ""
        AppLogger.shared.log("\(context) failed code=\(number)\(appName) message=\(message)")
    }

    private func currentFinderPath(allowAppleScript: Bool = true, preferAppleScript: Bool = false) -> String? {
        if preferAppleScript, allowAppleScript, !isExecutingAppleScript {
            if let scriptPath = currentFinderPathFromAppleScript() {
                return scriptPath
            }
        }

        if let axPath = currentFinderPathFromAX() {
            if axPathLooksConsistentWithFinderWindow(axPath) {
                return axPath
            }
            // Stale AXDocument (e.g. still Desktop while title is 未命名文件夹).
            if allowAppleScript, !isExecutingAppleScript,
               let scriptPath = currentFinderPathFromAppleScript() {
                return scriptPath
            }
            return axPath
        }

        guard allowAppleScript else { return nil }
        return currentFinderPathFromAppleScript()
    }

    private func currentFinderPathFromAppleScript() -> String? {
        let script = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            try
                return POSIX path of (target of front Finder window as alias)
            on error
                return ""
            end try
        end tell
        """
        guard let path = runFinderScript(script)?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return normalizePath(path)
    }

    private func currentFinderPathFromAX() -> String? {
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let window = attachedFinderWindowElement(for: finder) ?? frontFinderWindowElement(for: finder) else {
            return nil
        }

        var documentValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentValue) == .success,
           let document = documentValue as? String,
           let url = URL(string: document),
           url.isFileURL {
            var path = normalizePath(url.path)
            if path.hasSuffix("/"), path.count > 1 {
                path.removeLast()
            }
            if !path.isEmpty {
                return path
            }
        }

        // Some Finder windows expose a file URL via AXURL.
        var urlValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXURLAttribute as CFString, &urlValue) == .success {
            if let url = urlValue as? URL, url.isFileURL {
                return normalizePath(url.path)
            }
            if let urlString = urlValue as? String,
               let url = URL(string: urlString),
               url.isFileURL {
                return normalizePath(url.path)
            }
        }
        return nil
    }

    private func frontFinderWindowTitle() -> String? {
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let window = attachedFinderWindowElement(for: finder) ?? frontFinderWindowElement(for: finder) else {
            return nil
        }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else {
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// AXDocument often lags behind Finder navigation; window title usually updates first.
    private func axPathLooksConsistentWithFinderWindow(_ path: String) -> Bool {
        guard let title = frontFinderWindowTitle() else { return true }
        if title == "Finder" || title == "访达" { return true }

        let last = URL(fileURLWithPath: path).lastPathComponent
        if last == title { return true }

        // Localized special folder names.
        let aliases: [String: [String]] = [
            "Desktop": ["Desktop", "桌面"],
            "Documents": ["Documents", "文稿", "文档"],
            "Downloads": ["Downloads", "下载"],
            "Movies": ["Movies", "电影"],
            "Music": ["Music", "音乐"],
            "Pictures": ["Pictures", "图片"],
            "Library": ["Library", "资源库", "资料库"],
            "Applications": ["Applications", "应用程序"],
            "Users": ["Users", "用户"]
        ]
        if let names = aliases[last], names.contains(title) {
            return true
        }
        // Title matches somewhere in the path (rare, but safe).
        if path.split(separator: "/").map(String.init).contains(title) {
            return true
        }
        return false
    }

    private func currentFinderDirectoryURL() -> URL? {
        if let path = currentFinderPath(), !path.isEmpty {
            pathField.stringValue = path
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let path = directoryURLFromPathField()?.path else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func selectedFinderItemURLs() -> [URL] {
        let script = """
        tell application "Finder"
            set sel to selection
            if (count of sel) = 0 then return ""

            set paths to {}
            repeat with i in sel
                set end of paths to POSIX path of (i as alias)
            end repeat
            set AppleScript's text item delimiters to linefeed
            set resultText to paths as text
            set AppleScript's text item delimiters to ""
            return resultText
        end tell
        """
        guard let output = runFinderScript(script)?.stringValue else {
            return []
        }
        return output
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }

    private func updatePendingCutURLsFromPasteboard() {
        pendingCutURLs = clipboardFileURLs()
    }

    private func deleteSelectedFinderItemsToTrash() {
        AppLogger.shared.log("deleteSelectedFinderItemsToTrash")
        let selected = selectedFinderItemURLs()
        guard !selected.isEmpty else {
            NSSound.beep()
            showCloseFailure(localized("No selection", "未选中文件"))
            return
        }

        var records: [TrashedItemRecord] = []
        var failures = 0
        for url in selected {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                if let trashURL = resulting as? URL {
                    records.append(TrashedItemRecord(originalURL: url, trashURL: trashURL))
                } else if let resulting {
                    records.append(TrashedItemRecord(originalURL: url, trashURL: resulting as URL))
                } else {
                    failures += 1
                }
            } catch {
                failures += 1
                AppLogger.shared.log("trashItem failed path=\(url.path) error=\(error.localizedDescription)")
            }
        }

        lastTrashedItems = records
        updateUndoButtonState()

        if records.isEmpty {
            NSSound.beep()
            showCloseFailure(localized("Couldn't move to Trash", "无法移到废纸篓"))
            return
        }

        let message: String
        if failures == 0 {
            message = localized("Moved \(records.count) item(s) to Trash", "已移到废纸篓 \(records.count) 项")
        } else {
            message = localized("Trashed \(records.count), failed \(failures)", "已删除 \(records.count)，失败 \(failures)")
        }
        showCloseFailure(message)
        AppLogger.shared.log("deleteSelectedFinderItemsToTrash ok count=\(records.count) failures=\(failures)")
    }

    private func undoLastTrash() {
        guard !lastTrashedItems.isEmpty else {
            NSSound.beep()
            showCloseFailure(localized("Nothing to undo", "没有可撤销的删除"))
            return
        }

        var restored: [URL] = []
        var failures = 0
        for record in lastTrashedItems.reversed() {
            guard FileManager.default.fileExists(atPath: record.trashURL.path) else {
                failures += 1
                continue
            }
            let destination = uniqueRestoreURL(for: record.originalURL)
            do {
                try FileManager.default.moveItem(at: record.trashURL, to: destination)
                restored.append(destination)
            } catch {
                failures += 1
                AppLogger.shared.log("undoTrash failed from=\(record.trashURL.path) error=\(error.localizedDescription)")
            }
        }

        lastTrashedItems = []
        updateUndoButtonState()

        if restored.isEmpty {
            NSSound.beep()
            showCloseFailure(localized("Couldn't undo trash", "无法撤销删除"))
            return
        }

        showCloseFailure(localized("Restored \(restored.count) item(s)", "已还原 \(restored.count) 项"))
        AppLogger.shared.log("undoLastTrash restored=\(restored.count) failures=\(failures)")
        revealRestoredItems(restored)
    }

    private func uniqueRestoreURL(for original: URL) -> URL {
        if !FileManager.default.fileExists(atPath: original.path) {
            return original
        }
        let folder = original.deletingLastPathComponent()
        let name = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var index = 1
        while true {
            let candidateName = ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func revealRestoredItems(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let list = urls.map { "POSIX file \"\(escapedAppleScript($0.path))\"" }.joined(separator: ", ")
        runFinderScriptAsync("""
        tell application "Finder"
            activate
            try
                reveal {\(list)}
                select {\(list)}
            end try
        end tell
        """)
    }

    private func updateUndoButtonState() {
        guard let undoButton else { return }
        let enabled = !lastTrashedItems.isEmpty
        setButton(undoButton, enabled: enabled)
    }

    private func clipboardFileURLs() -> [URL] {
        let pasteboard = NSPasteboard.general
        var fileURLs: [URL] = []

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let filenames = pasteboard.propertyList(forType: filenamesType) as? [String], !filenames.isEmpty {
            fileURLs.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            fileURLs.append(contentsOf: urls.filter { $0.isFileURL })
        }

        var seenPaths = Set<String>()
        return fileURLs.filter { url in
            let path = url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { return false }
            seenPaths.insert(path)
            return FileManager.default.fileExists(atPath: path)
        }
    }

    private func movePendingCutItemsToCurrentDirectory() {
        guard let destinationDirectory = currentFinderDirectoryURL() else {
            pendingCutURLs.removeAll()
            hasPendingCut = false
            NSSound.beep()
            return
        }

        let sourceURLs = pendingCutURLs
        pendingCutURLs.removeAll()
        hasPendingCut = false

        do {
            var movedURLs: [URL] = []
            for sourceURL in sourceURLs {
                let standardizedSource = sourceURL.standardizedFileURL
                let destinationURL = uniqueMoveDestination(for: standardizedSource, in: destinationDirectory)
                guard standardizedSource.path != destinationURL.standardizedFileURL.path else {
                    movedURLs.append(standardizedSource)
                    continue
                }
                try FileManager.default.moveItem(at: standardizedSource, to: destinationURL)
                movedURLs.append(destinationURL)
            }
            refreshPathFromFinder()
            updatePanelFrame()
            showCloseFailure(localized("Moved \(movedURLs.count) item(s)", "已移动 \(movedURLs.count) 项"))
        } catch {
            NSSound.beep()
            showCloseFailure(localized("Move failed", "移动失败"))
        }
    }

    @discardableResult
    private func copyClipboardItemsToCurrentDirectory() -> Bool {
        let sourceURLs = clipboardFileURLs()
        guard !sourceURLs.isEmpty else { return false }
        guard let destinationDirectory = currentFinderDirectoryURL() else {
            NSSound.beep()
            return true
        }

        do {
            for sourceURL in sourceURLs {
                let standardizedSource = sourceURL.standardizedFileURL
                let destinationURL = uniqueCopyDestination(for: standardizedSource, in: destinationDirectory)
                try FileManager.default.copyItem(at: standardizedSource, to: destinationURL)
            }
            refreshPathFromFinder()
            updatePanelFrame()
            return true
        } catch {
            NSSound.beep()
            showCloseFailure(localized("Copy failed", "复制失败"))
            return true
        }
    }

    private func uniqueMoveDestination(for sourceURL: URL, in destinationDirectory: URL) -> URL {
        let fileName = sourceURL.lastPathComponent
        let candidate = destinationDirectory.appendingPathComponent(fileName)
        // Same folder / same name: no-op.
        guard candidate.standardizedFileURL.path != sourceURL.standardizedFileURL.path else {
            return candidate
        }
        // Match Finder: name → name 副本 → name 副本 2 …
        return uniqueCopyDestination(for: sourceURL, in: destinationDirectory)
    }

    private func uniqueCopyDestination(for sourceURL: URL, in destinationDirectory: URL) -> URL {
        let fileName = sourceURL.lastPathComponent
        var candidate = destinationDirectory.appendingPathComponent(fileName)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }

        func copyCandidate(_ suffix: String) -> URL {
            var url = destinationDirectory.appendingPathComponent("\(baseName) \(suffix)")
            if !pathExtension.isEmpty {
                url.appendPathExtension(pathExtension)
            }
            return url
        }

        candidate = copyCandidate("副本")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = copyCandidate("副本 \(index)")
            index += 1
        }
        return candidate
    }

    private func uniqueURL(in directory: URL, baseName: String, extensionName: String?) -> URL {
        func candidate(_ suffix: String?) -> URL {
            let fileName = suffix.map { "\(baseName) \($0)" } ?? baseName
            if let extensionName {
                return directory.appendingPathComponent(fileName).appendingPathExtension(extensionName)
            }
            return directory.appendingPathComponent(fileName, isDirectory: true)
        }

        var url = candidate(nil)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url
        }

        url = candidate("副本")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate("副本 \(index)")
            index += 1
        }
        return url
    }

    private func defaultFileContents(for extensionName: String, directory: URL) -> String {
        switch extensionName.lowercased() {
        case "r":
            return "setwd(\"\(escapedRString(directory.path))\")\n"
        case "py":
            return "# New Python script\n"
        default:
            return ""
        }
    }

    /// Real Office Open XML packages (zip). Empty `.xlsx` / `.docx` files are not valid.
    private func defaultBinaryFileContents(for extensionName: String) -> Data? {
        switch extensionName.lowercased() {
        case "xlsx":
            return blankXLSXData()
        case "docx":
            return blankDOCXData()
        case "pptx":
            return blankPPTXData()
        default:
            return nil
        }
    }

    private func blankXLSXData() -> Data {
        zipArchive(entries: [
            ("[Content_Types].xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
  <Override PartName="/xl/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
"""#),
            ("_rels/.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
"""#),
            ("docProps/core.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title></dc:title>
  <dc:creator>FinderPathBar</dc:creator>
  <cp:lastModifiedBy>FinderPathBar</cp:lastModifiedBy>
  <dcterms:created xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:modified>
</cp:coreProperties>
"""#),
            ("docProps/app.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>FinderPathBar</Application>
  <DocSecurity>0</DocSecurity>
  <ScaleCrop>false</ScaleCrop>
  <SharedDoc>false</SharedDoc>
  <HyperlinksChanged>false</HyperlinksChanged>
  <AppVersion>1.0</AppVersion>
</Properties>
"""#),
            ("xl/workbook.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <fileVersion appName="xl"/>
  <workbookPr/>
  <bookViews>
    <workbookView xWindow="0" yWindow="0" windowWidth="24000" windowHeight="15000"/>
  </bookViews>
  <sheets>
    <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
  </sheets>
  <calcPr calcId="0"/>
</workbook>
"""#),
            ("xl/_rels/workbook.xml.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>
"""#),
            ("xl/worksheets/sheet1.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <dimension ref="A1"/>
  <sheetViews>
    <sheetView workbookViewId="0"/>
  </sheetViews>
  <sheetFormatPr defaultRowHeight="15"/>
  <sheetData/>
  <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>
</worksheet>
"""#),
            ("xl/styles.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/><scheme val="minor"/></font></fonts>
  <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
"""#),
            ("xl/sharedStrings.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="0" uniqueCount="0"/>
"""#),
            ("xl/theme/theme1.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">
  <a:themeElements>
    <a:clrScheme name="Office">
      <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
      <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
      <a:dk2><a:srgbClr val="1F497D"/></a:dk2>
      <a:lt2><a:srgbClr val="EEECE1"/></a:lt2>
      <a:accent1><a:srgbClr val="4F81BD"/></a:accent1>
      <a:accent2><a:srgbClr val="C0504D"/></a:accent2>
      <a:accent3><a:srgbClr val="9BBB59"/></a:accent3>
      <a:accent4><a:srgbClr val="8064A2"/></a:accent4>
      <a:accent5><a:srgbClr val="4BACC6"/></a:accent5>
      <a:accent6><a:srgbClr val="F79646"/></a:accent6>
      <a:hlink><a:srgbClr val="0000FF"/></a:hlink>
      <a:folHlink><a:srgbClr val="800080"/></a:folHlink>
    </a:clrScheme>
    <a:fontScheme name="Office">
      <a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
      <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
    </a:fontScheme>
    <a:fmtScheme name="Office">
      <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      </a:fillStyleLst>
      <a:lnStyleLst>
        <a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
        <a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
        <a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
      </a:lnStyleLst>
      <a:effectStyleLst>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
      </a:effectStyleLst>
      <a:bgFillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
      </a:bgFillStyleLst>
    </a:fmtScheme>
  </a:themeElements>
</a:theme>
"""#)
        ])
    }

    private func blankDOCXData() -> Data {
        zipArchive(entries: [
            ("[Content_Types].xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"""#),
            ("_rels/.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""#),
            ("word/document.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t></w:t></w:r></w:p>
    <w:sectPr/>
  </w:body>
</w:document>
"""#),
            ("word/_rels/document.xml.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
"""#)
        ])
    }

    private func blankPPTXData() -> Data {
        zipArchive(entries: [
            ("[Content_Types].xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
  <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
  <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
  <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
</Types>
"""#),
            ("_rels/.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
</Relationships>
"""#),
            ("ppt/presentation.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:sldIdLst>
    <p:sldId id="256" r:id="rId1"/>
  </p:sldIdLst>
  <p:sldSz cx="12192000" cy="6858000"/>
</p:presentation>
"""#),
            ("ppt/_rels/presentation.xml.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
</Relationships>
"""#),
            ("ppt/slides/slide1.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld><p:spTree>
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
    <p:grpSpPr/>
  </p:spTree></p:cSld>
</p:sld>
"""#),
            ("ppt/slides/_rels/slide1.xml.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
</Relationships>
"""#),
            ("ppt/slideLayouts/slideLayout1.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">
  <p:cSld name="Blank"><p:spTree>
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
    <p:grpSpPr/>
  </p:spTree></p:cSld>
</p:sldLayout>
"""#),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
</Relationships>
"""#),
            ("ppt/slideMasters/slideMaster1.xml", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld><p:bg/><p:spTree>
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
    <p:grpSpPr/>
  </p:spTree></p:cSld>
  <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
</p:sldMaster>
"""#),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", #"""
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
</Relationships>
"""#)
        ])
    }

    /// Minimal ZIP (store-only) writer for Office Open XML packages.
    private func zipArchive(entries: [(String, String)]) -> Data {
        var localFiles = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        func appendUInt16(_ value: UInt16, to data: inout Data) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32, to data: inout Data) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        for (path, text) in entries {
            let nameData = Data(path.utf8)
            let fileData = Data(text.utf8)
            let crc = crc32(fileData)
            let size = UInt32(fileData.count)
            let nameLength = UInt16(nameData.count)
            let localHeaderOffset = offset

            var local = Data()
            appendUInt32(0x04034b50, to: &local) // local file header
            appendUInt16(20, to: &local) // version needed
            appendUInt16(0, to: &local) // flags
            appendUInt16(0, to: &local) // method = store
            appendUInt16(0, to: &local) // time
            appendUInt16(0, to: &local) // date
            appendUInt32(crc, to: &local)
            appendUInt32(size, to: &local)
            appendUInt32(size, to: &local)
            appendUInt16(nameLength, to: &local)
            appendUInt16(0, to: &local) // extra length
            local.append(nameData)
            local.append(fileData)
            localFiles.append(local)

            var central = Data()
            appendUInt32(0x02014b50, to: &central) // central directory header
            appendUInt16(20, to: &central) // version made by
            appendUInt16(20, to: &central) // version needed
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central)
            appendUInt32(crc, to: &central)
            appendUInt32(size, to: &central)
            appendUInt32(size, to: &central)
            appendUInt16(nameLength, to: &central)
            appendUInt16(0, to: &central)
            appendUInt16(0, to: &central) // comment
            appendUInt16(0, to: &central) // disk start
            appendUInt16(0, to: &central) // internal attrs
            appendUInt32(0, to: &central) // external attrs
            appendUInt32(localHeaderOffset, to: &central)
            central.append(nameData)
            centralDirectory.append(central)

            offset += UInt32(local.count)
        }

        let centralSize = UInt32(centralDirectory.count)
        let centralOffset = offset
        var end = Data()
        appendUInt32(0x06054b50, to: &end)
        appendUInt16(0, to: &end)
        appendUInt16(0, to: &end)
        appendUInt16(UInt16(entries.count), to: &end)
        appendUInt16(UInt16(entries.count), to: &end)
        appendUInt32(centralSize, to: &end)
        appendUInt32(centralOffset, to: &end)
        appendUInt16(0, to: &end)

        var result = Data()
        result.append(localFiles)
        result.append(centralDirectory)
        result.append(end)
        return result
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xedb88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xffff_ffff
    }

    private func frontFinderWindowID() -> Int? {
        // AX only — AppleScript here was invoked from the follow timer via
        // defaultPanelFrame and crashed (SIGSEGV) when Excel/WPS became frontmost.
        axFrontFinderWindowID()
    }

    private func axFrontFinderWindowID() -> Int? {
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let window = attachedFinderWindowElement(for: finder) ?? frontFinderWindowElement(for: finder) else {
            return nil
        }
        return axWindowNumber(window)
    }

    private func normalizePath(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func frontFinderWindowBounds() -> NSRect? {
        // CGWindowList tracks live resize; AX/AppleScript often lag until mouse-up
        // or app switch — which is why FP width used to catch up only then.
        // Never fall back to AppleScript here: mouse/timer/hot paths + NSAppleScript
        // re-enter the run loop and have crashed with dispatch_sync / SIGSEGV.
        if let cgBounds = frontFinderWindowBoundsFromCG() {
            return cgBounds
        }
        if let axBounds = frontFinderWindowBoundsFromAX() {
            return axBounds
        }
        return lastFinderWindowBounds
    }

    private func frontFinderWindowBoundsFromCG() -> NSRect? {
        let resolvedID: Int? = {
            if let attachedFinderWindowID {
                return attachedFinderWindowID
            }
            guard ensureAccessibilityPermission(prompt: false),
                  let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                  let window = attachedFinderWindowElement(for: finder) ?? frontFinderWindowElement(for: finder) else {
                return nil
            }
            return axWindowNumber(window)
        }()
        guard let windowID = resolvedID else { return nil }

        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var quartzRect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict, &quartzRect) else {
            return nil
        }
        return quartzRectToAppKit(quartzRect)
    }

    private func frontFinderWindowBoundsFromAX() -> NSRect? {
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let window = attachedFinderWindowElement(for: finder) ?? frontFinderWindowElement(for: finder),
              let rect = axWindowRect(window) else {
            return nil
        }
        return rect
    }

    private func updateAttachedFinderWindowID() {
        if let number = axFrontFinderWindowID() {
            attachedFinderWindowID = number
        }
    }

    private func frontFinderContentBounds() -> NSRect? {
        guard isFinderFrontmost else { return nil }
        guard ensureAccessibilityPermission(prompt: false),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let window = attachedFinderWindowElement(for: finder) ?? frontFinderWindowElement(for: finder),
              let windowRect = axWindowRect(window) else {
            return nil
        }

        let descendants = axDescendants(of: window, limit: 140)
        let candidates = descendants.compactMap { element -> NSRect? in
            guard let rect = axElementScreenRect(element) else { return nil }
            let converted = quartzRectToAppKit(rect)
            guard converted.width > windowRect.width * 0.35,
                  converted.height > windowRect.height * 0.35,
                  converted.minX >= windowRect.minX - 8,
                  converted.maxX <= windowRect.maxX + 8,
                  converted.minY >= windowRect.minY - 8,
                  converted.maxY <= windowRect.maxY - 45 else {
                return nil
            }
            return converted
        }

        return candidates.max { lhs, rhs in
            func score(_ rect: NSRect) -> CGFloat {
                let areaScore = rect.width * rect.height
                let rightEdgeScore = -abs(rect.maxX - windowRect.maxX) * 50
                let bottomScore = -abs(rect.minY - windowRect.minY) * 20
                // Prefer content inset by a sidebar, but don't overweight it so that
                // a true full-width view (sidebar hidden) can still win on area.
                let leftInset = rect.minX - windowRect.minX
                let sidebarScore: CGFloat
                if leftInset > 60, leftInset < windowRect.width * 0.45 {
                    sidebarScore = leftInset * 3
                } else {
                    sidebarScore = 0
                }
                return areaScore + rightEdgeScore + bottomScore + sidebarScore
            }
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            return lhsScore < rhsScore
        }
    }

    private func frontFinderWindowElement(for finder: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            return unsafeBitCast(focusedValue, to: AXUIElement.self)
        }
        guard isFinderFrontmost else {
            return nil
        }
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }
        return windows.first
    }

    private func axDescendants(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [AXUIElement] = [element]
        while !queue.isEmpty && result.count < limit {
            let current = queue.removeFirst()
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else {
                continue
            }
            for child in children where result.count < limit {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private func quartzRectToAppKit(_ rect: CGRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)) }) ?? NSScreen.main else {
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
        return NSRect(x: rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func frontFinderAppleScriptBounds() -> FinderBounds? {
        let script = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            set b to bounds of front Finder window
            return (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
        end tell
        """
        guard let value = runFinderScript(script)?.stringValue else {
            return nil
        }

        let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }

        return FinderBounds(left: CGFloat(parts[0]), top: CGFloat(parts[1]), right: CGFloat(parts[2]), bottom: CGFloat(parts[3]))
    }

    private func setFrontFinderBounds(_ bounds: FinderBounds) {
        runFinderScript("""
        tell application "Finder"
            if (count of Finder windows) = 0 then return
            set bounds of front Finder window to {\(Int(bounds.left)), \(Int(bounds.top)), \(Int(bounds.right)), \(Int(bounds.bottom))}
        end tell
        """)
    }

    private func screenContaining(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }
}

private final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1

    func acquire() -> Bool {
        guard fileDescriptor == -1 else { return true }

        let fileManager = FileManager.default
        guard let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }

        let lockDirectory = applicationSupportDirectory.appendingPathComponent("FinderPathBar", isDirectory: true)
        do {
            try fileManager.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let lockURL = lockDirectory.appendingPathComponent("FinderPathBar.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        fileDescriptor = descriptor
        return true
    }

    deinit {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

private final class AddressBarPanel: NSPanel {
    var allowsKeyFocus = false

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { allowsKeyFocus }
}

private class NonActivatingButton: NSButton {
    var mouseDownHandler: (() -> Void)?
    var mouseDownEventHandler: ((NSEvent) -> Void)?
    var rightMouseDownHandler: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if let mouseDownEventHandler {
            mouseDownEventHandler(event)
            return
        }
        mouseDownHandler?()
    }

    override func rightMouseDown(with event: NSEvent) {
        rightMouseDownHandler?()
    }
}

private final class BookmarkFolderButton: NonActivatingButton {
    var onClick: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    private var mouseDownLocation = NSPoint.zero
    private var isDraggingFolder = false
    private var didReceiveMouseDown = false

    override func mouseDown(with event: NSEvent) {
        didReceiveMouseDown = true
        mouseDownLocation = event.locationInWindow
        isDraggingFolder = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard didReceiveMouseDown else { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        let dy = event.locationInWindow.y - mouseDownLocation.y
        if hypot(dx, dy) >= 3 {
            isDraggingFolder = true
            alphaValue = 0.62
            onDrag?(NSEvent.mouseLocation)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            didReceiveMouseDown = false
            isDraggingFolder = false
            alphaValue = 1
        }
        // Ignore stray mouseUps that never had a matching mouseDown on this
        // button (common when AppleScript re-enters the run loop mid-click).
        guard didReceiveMouseDown else { return }
        let pointInButton = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -2).contains(pointInButton) else { return }

        if isDraggingFolder {
            onDrop?(NSEvent.mouseLocation)
        } else {
            onClick?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Keep state; mouseUp still decides.
    }
}

private final class HistoryButton: NSButton {
    var mouseDownHandler: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownHandler?()
    }
}

private struct FinderBounds {
    let left: CGFloat
    let top: CGFloat
    let right: CGFloat
    let bottom: CGFloat

    var width: CGFloat { right - left }
    var height: CGFloat { bottom - top }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> FinderBounds {
        FinderBounds(left: left + dx, top: top + dy, right: right + dx, bottom: bottom + dy)
    }
}

private struct HistoryEntry {
    let path: String
    let openedAt: Date
}

private struct GitHubReleaseInfo: Decodable {
    let tag_name: String
    let assets: [GitHubReleaseAsset]
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browser_download_url: String
}

private struct Bookmark: Codable, Equatable {
    let id: UUID
    let folder: String
    let name: String
    let path: String

    init(id: UUID = UUID(), folder: String, name: String, path: String) {
        self.id = id
        self.folder = folder
        self.name = name
        self.path = path
    }
}

private struct TrashedItemRecord {
    let originalURL: URL
    let trashURL: URL
}

private struct BookmarkExportPayload: Codable {
    var version: Int
    var exportedAt: Date
    var bookmarks: [Bookmark]
    var folderOrder: [String]
}

private struct CloseResult {
    let didClose: Bool
    let message: String

    init(_ didClose: Bool, _ message: String) {
        self.didClose = didClose
        self.message = message
    }
}

private struct ToolbarMenuItem {
    let title: String
    let action: () -> Void
    let editAction: (() -> Void)?

    init(title: String, action: @escaping () -> Void, editAction: (() -> Void)? = nil) {
        self.title = title
        self.action = action
        self.editAction = editAction
    }
}

private final class HistoryListView: NSView {
    private var onSelect: ((String) -> Void)?
    private var backgroundColor = NSColor.white

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(entries: [HistoryEntry], formatter: DateFormatter, pathFontSize: CGFloat, backgroundColor: NSColor, emptyText: String, onSelect: @escaping (String) -> Void) {
        subviews.forEach { $0.removeFromSuperview() }
        self.onSelect = onSelect
        setBackgroundColor(backgroundColor)

        if entries.isEmpty {
            let row = makeRow(path: emptyText, time: "", pathFontSize: pathFontSize, enabled: false, pathExists: true)
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 26)
            ])
            return
        }

        var previous: NSView?
        for entry in entries {
            let row = makeRow(
                path: entry.path,
                time: formatter.string(from: entry.openedAt),
                pathFontSize: pathFontSize,
                enabled: true,
                pathExists: FileManager.default.fileExists(atPath: entry.path)
            )
            row.identifier = NSUserInterfaceItemIdentifier(entry.path)
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 26)
            ])
            if let previous {
                row.topAnchor.constraint(equalTo: previous.bottomAnchor).isActive = true
            } else {
                row.topAnchor.constraint(equalTo: topAnchor).isActive = true
            }
            previous = row
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = subviews.first(where: { $0.frame.contains(point) }),
              let path = row.identifier?.rawValue,
              !path.isEmpty else {
            return
        }
        onSelect?(path)
    }

    private func makeRow(path: String, time: String, pathFontSize: CGFloat, enabled: Bool, pathExists: Bool) -> NSView {
        let row = HistoryRowView()
        row.defaultBackgroundColor = backgroundColor
        row.isHoverEnabled = enabled
        row.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: path)
        pathLabel.font = .monospacedSystemFont(ofSize: pathFontSize, weight: .regular)
        pathLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let missingLabel = NSTextField(labelWithString: pathExists ? "" : "x")
        missingLabel.font = .systemFont(ofSize: max(10, pathFontSize - 1), weight: .bold)
        missingLabel.textColor = .systemRed
        missingLabel.alignment = .center
        missingLabel.translatesAutoresizingMaskIntoConstraints = false

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .monospacedSystemFont(ofSize: max(9, pathFontSize - 2), weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.lineBreakMode = .byClipping
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(pathLabel)
        row.addSubview(missingLabel)
        row.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(equalTo: missingLabel.leadingAnchor, constant: -10),
            pathLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            missingLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -5),
            missingLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            missingLabel.widthAnchor.constraint(equalToConstant: 12),

            timeLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            timeLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 170)
        ])
        return row
    }

    func setBackgroundColor(_ color: NSColor) {
        backgroundColor = color
        layer?.backgroundColor = color.cgColor
        for row in subviews.compactMap({ $0 as? HistoryRowView }) {
            row.defaultBackgroundColor = color
        }
    }
}

private final class HistoryRowView: NSView {
    var isHoverEnabled = false
    var defaultBackgroundColor = NSColor.white {
        didSet {
            layer?.backgroundColor = defaultBackgroundColor.cgColor
        }
    }
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = defaultBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isHoverEnabled else { return }
        layer?.backgroundColor = NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.98, alpha: 1).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = defaultBackgroundColor.cgColor
    }
}

private final class ToolbarMenuPanel: NSPanel {
    var rows: [ToolbarMenuRowView] = []

    override var acceptsMouseMovedEvents: Bool {
        get { true }
        set { }
    }

    override func mouseMoved(with event: NSEvent) {
        let windowPoint = event.locationInWindow
        for row in rows {
            let point = row.convert(windowPoint, from: nil)
            row.setHovered(row.bounds.contains(point))
        }
    }
}

private final class BookmarkMenuRowView: NSView {
    var onOpen: (() -> Void)?
    var onEdit: (() -> Void)?
    private let label: NSTextField
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, path: String, font: NSFont, width: CGFloat) {
        self.label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        toolTip = path
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        label.font = font
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedMenuItemColor.cgColor
        label.textColor = .selectedMenuItemTextColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        label.textColor = .labelColor
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onOpen?()
    }

    override func mouseDown(with event: NSEvent) {
        // Intentionally ignore mouseDown so menu teardown / nested run-loop
        // mouseUps from other clicks cannot trigger open. Click = mouseUp.
    }

    override func rightMouseDown(with event: NSEvent) {
        onEdit?()
    }
}

private final class ToolbarMenuRowView: NSView {
    var onSelect: (() -> Void)?
    var onEdit: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private let label: NSTextField

    init(title: String, font: NSFont) {
        self.label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        label.font = font
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onEdit?()
    }

    func setHovered(_ isHovered: Bool) {
        layer?.backgroundColor = (isHovered
            ? NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.72, alpha: 1)
            : NSColor.white
        ).cgColor
        label.textColor = isHovered ? .white : .labelColor
    }
}

private final class BreadcrumbScrollView: NSScrollView {
    var onEmptyClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let documentView,
           let hit = documentView.hitTest(documentView.convert(point, from: self)),
           hit !== documentView {
            // Let breadcrumb buttons handle their own clicks.
            super.mouseDown(with: event)
            return
        }
        onEmptyClick?()
    }
}

private final class AutocompleteRowView: NSView {
    var onSelect: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var plainText = ""
    private var highlightQuery = ""
    private var fontSize: CGFloat = 13
    private var isSelected = false
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.wraps = false
        label.cell?.isScrollable = true
        label.cell?.truncatesLastVisibleLine = true
        label.allowsEditingTextAttributes = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 16)
        ])
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(text: String, fontSize: CGFloat, selected: Bool, highlightQuery: String = "") {
        plainText = text
        self.fontSize = fontSize
        self.highlightQuery = highlightQuery
        isSelected = selected
        isHovered = false
        applyAppearance()
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        applyAppearance()
    }

    private func applyAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.98, alpha: 1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        label.attributedStringValue = makeHighlightedText()
    }

    private func makeHighlightedText() -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let baseColor: NSColor = isSelected ? .selectedMenuItemTextColor : .labelColor
        let matchColor: NSColor = isSelected
            ? NSColor.systemYellow
            : NSColor.systemOrange
        let matchFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.lineSpacing = 0

        let attributed = NSMutableAttributedString(string: plainText, attributes: [
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: paragraph
        ])
        let query = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return attributed }

        let keywords = query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        let nsString = plainText as NSString
        for keyword in keywords {
            var searchRange = NSRange(location: 0, length: nsString.length)
            while searchRange.length > 0 {
                let found = nsString.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                attributed.addAttributes([
                    .foregroundColor: matchColor,
                    .font: matchFont,
                    .paragraphStyle: paragraph
                ], range: found)
                let nextLocation = found.location + max(found.length, 1)
                if nextLocation >= nsString.length { break }
                searchRange = NSRange(location: nextLocation, length: nsString.length - nextLocation)
            }
        }
        return attributed
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}

private final class AutocompleteListView: NSView {
    var onSelect: ((String) -> Void)?
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusBottomConstraint: NSLayoutConstraint!
    private var scrollBottomToStatusConstraint: NSLayoutConstraint!
    private var scrollBottomToSelfConstraint: NSLayoutConstraint!
    private var rows: [String] = []
    private var selectedIndex = 0
    private var fontSize: CGFloat = 13
    private var backgroundColor: NSColor = .white
    private var statusText: String = ""
    private var highlightQuery: String = ""
    private let rowHeight: CGFloat = 20
    private let statusHeight: CGFloat = 18
    private var trackingAreaRef: NSTrackingArea?
    private var scrollBoundsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        addSubview(scrollView)

        // Wheel-scroll moves rows under a stationary cursor; refresh hover from
        // the real mouse location instead of relying on per-row enter/exit.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateHoverForCurrentMouseLocation()
        }

        statusLabel.isBordered = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.drawsBackground = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        addSubview(statusLabel)

        statusBottomConstraint = statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        scrollBottomToStatusConstraint = scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2)
        scrollBottomToSelfConstraint = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollBottomToSelfConstraint,

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: statusHeight - 6),
            statusBottomConstraint
        ])
        statusBottomConstraint.isActive = false
    }

    deinit {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(rows: [String], selectedIndex: Int, fontSize: CGFloat, backgroundColor: NSColor, statusText: String = "", highlightQuery: String = "") {
        self.rows = rows
        self.selectedIndex = selectedIndex
        self.fontSize = fontSize
        self.backgroundColor = backgroundColor
        self.statusText = statusText
        self.highlightQuery = highlightQuery
        layer?.backgroundColor = backgroundColor.cgColor
        updateStatusLayout()
        rebuild()
        updateHoverForCurrentMouseLocation()
    }

    func select(index: Int) {
        selectedIndex = index
        rebuild()
        if rows.indices.contains(index) {
            scrollSelectedIntoView()
        }
        updateHoverForCurrentMouseLocation()
    }

    private func updateStatusLayout() {
        let showStatus = !statusText.isEmpty
        statusLabel.stringValue = statusText
        statusLabel.isHidden = !showStatus
        scrollBottomToSelfConstraint.isActive = !showStatus
        scrollBottomToStatusConstraint.isActive = showStatus
        statusBottomConstraint.isActive = showStatus
    }

    private func rebuild() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let contentHeight = max(rowHeight, CGFloat(rows.count) * rowHeight)
        let width = max(bounds.width, scrollView.contentSize.width)
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

        for (index, row) in rows.enumerated() {
            let y = contentHeight - CGFloat(index + 1) * rowHeight
            let rowView = AutocompleteRowView(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
            rowView.autoresizingMask = [.width]
            rowView.configure(
                text: row,
                fontSize: fontSize,
                selected: index == selectedIndex,
                highlightQuery: highlightQuery
            )
            rowView.onSelect = { [weak self] in
                guard let self, self.rows.indices.contains(index) else { return }
                self.onSelect?(self.rows[index])
            }
            documentView.addSubview(rowView)
        }
    }

    private func scrollSelectedIntoView() {
        guard rows.indices.contains(selectedIndex) else { return }
        let contentHeight = documentView.bounds.height
        let selectedTop = contentHeight - CGFloat(selectedIndex + 1) * rowHeight
        let visible = scrollView.contentView.bounds
        if selectedTop < visible.minY {
            documentView.scroll(NSPoint(x: 0, y: selectedTop))
        } else if selectedTop + rowHeight > visible.maxY {
            documentView.scroll(NSPoint(x: 0, y: selectedTop + rowHeight - visible.height))
        }
    }

    private func updateHoverForCurrentMouseLocation() {
        guard let window else {
            clearAllHovers()
            return
        }
        updateHover(atWindowPoint: window.mouseLocationOutsideOfEventStream)
    }

    private func updateHover(atWindowPoint windowPoint: NSPoint) {
        let pointInScroll = scrollView.convert(windowPoint, from: nil)
        guard scrollView.bounds.contains(pointInScroll) else {
            clearAllHovers()
            return
        }
        let pointInDoc = documentView.convert(windowPoint, from: nil)
        for case let row as AutocompleteRowView in documentView.subviews {
            row.setHovered(row.frame.contains(pointInDoc))
        }
    }

    private func clearAllHovers() {
        for case let row as AutocompleteRowView in documentView.subviews {
            row.setHovered(false)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        clearAllHovers()
    }

    override func layout() {
        super.layout()
        rebuild()
        scrollSelectedIntoView()
        updateHoverForCurrentMouseLocation()
    }
}

private final class PathTextField: NSTextField {
    var beginEditingHandler: (() -> Void)?
    var doubleClickHandler: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let index = characterIndex(for: event) {
            doubleClickHandler?(index)
            return
        }
        beginEditingHandler?()
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch characters {
        case "c":
            currentEditor()?.copy(nil)
            return true
        case "v":
            currentEditor()?.paste(nil)
            return true
        case "x":
            currentEditor()?.cut(nil)
            return true
        case "a":
            selectText(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func characterIndex(for event: NSEvent) -> Int? {
        characterIndex(at: convert(event.locationInWindow, from: nil))
    }

    func characterIndex(at localPoint: NSPoint) -> Int? {
        guard let font else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var width: CGFloat = 0
        let chars = Array(stringValue)
        for (index, char) in chars.enumerated() {
            let charWidth = String(char).size(withAttributes: attributes).width
            if localPoint.x <= width + charWidth / 2 {
                return index
            }
            width += charWidth
        }
        return max(chars.count - 1, 0)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, let value = Int(raw, radix: 16) else {
            self.init(srgbRed: 0.945, green: 0.949, blue: 0.953, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = Int((red * 255).rounded(.toNearestOrEven))
        let g = Int((green * 255).rounded(.toNearestOrEven))
        let b = Int((blue * 255).rounded(.toNearestOrEven))
        return String(format: "#%02x%02x%02x", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

private extension NSView {
    func firstDescendant(where predicate: (NSView) -> Bool) -> NSView? {
        for subview in subviews {
            if predicate(subview) {
                return subview
            }
            if let match = subview.firstDescendant(where: predicate) {
                return match
            }
        }
        return nil
    }
}

private final class FirstMouseCheckbox: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class AppLogger {
    static let shared = AppLogger()

    var logURL: URL {
        logDirectory.appendingPathComponent("\(fileDateFormatter.string(from: Date())).txt")
    }
    private let queue = DispatchQueue(label: "FinderPathBar.AppLogger")
    private let logDirectory: URL
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    private let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var didInstallCrashHandlers = false
    private let maxLogBytes: UInt64 = 2 * 1024 * 1024

    private init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        logDirectory = documentsDirectory.appendingPathComponent("FinderPathBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    func installCrashHandlers() {
        guard !didInstallCrashHandlers else { return }
        didInstallCrashHandlers = true

        NSSetUncaughtExceptionHandler { exception in
            AppLogger.shared.logSync("uncaughtException name=\(exception.name.rawValue) reason=\(exception.reason ?? "nil") callStack=\(exception.callStackSymbols.joined(separator: " | "))")
        }

        signal(SIGABRT) { signalNumber in AppLogger.handleSignal(signalNumber) }
        signal(SIGILL) { signalNumber in AppLogger.handleSignal(signalNumber) }
        signal(SIGSEGV) { signalNumber in AppLogger.handleSignal(signalNumber) }
        signal(SIGFPE) { signalNumber in AppLogger.handleSignal(signalNumber) }
        signal(SIGBUS) { signalNumber in AppLogger.handleSignal(signalNumber) }
        signal(SIGPIPE) { signalNumber in AppLogger.handleSignal(signalNumber) }
        signal(SIGTERM) { signalNumber in AppLogger.handleSignal(signalNumber) }
    }

    func log(_ message: String) {
        queue.async {
            self.write(message)
        }
    }

    func logSync(_ message: String) {
        write(message)
    }

    func revealInFinder() {
        let currentLogURL = logURL
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: currentLogURL.path) {
            logSync("log file created")
        }
        NSWorkspace.shared.activateFileViewerSelecting([currentLogURL])
    }

    private static func handleSignal(_ signalNumber: Int32) {
        // Best-effort sync log; then restore default and re-raise.
        let name: String
        switch signalNumber {
        case SIGABRT: name = "SIGABRT"
        case SIGILL: name = "SIGILL"
        case SIGSEGV: name = "SIGSEGV"
        case SIGFPE: name = "SIGFPE"
        case SIGBUS: name = "SIGBUS"
        case SIGPIPE: name = "SIGPIPE"
        case SIGTERM: name = "SIGTERM"
        default: name = "signal(\(signalNumber))"
        }
        AppLogger.shared.logSync("fatalSignal \(name)")
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }

    private func write(_ message: String) {
        rotateIfNeeded()
        let currentLogURL = logURL
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let thread = Thread.isMainThread ? "main" : "bg"
        let line = "[\(formatter.string(from: Date()))] [pid:\(ProcessInfo.processInfo.processIdentifier)] [\(thread)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        // Prefer POSIX append so an editor locking/replacing the file cannot
        // wipe the whole log via Data.write overwrite fallback.
        let fd = open(currentLogURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        if fd >= 0 {
            data.withUnsafeBytes { rawBuffer in
                if let base = rawBuffer.baseAddress {
                    _ = Darwin.write(fd, base, rawBuffer.count)
                }
            }
            close(fd)
            return
        }
        try? data.write(to: currentLogURL, options: .atomic)
    }

    private func rotateIfNeeded() {
        let currentLogURL = logURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
              let fileSize = attributes[.size] as? UInt64,
              fileSize > maxLogBytes else {
            return
        }
        let oldURL = currentLogURL.deletingPathExtension().appendingPathExtension("old.txt")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: currentLogURL, to: oldURL)
    }
}

private final class UpdateDownloadController: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?
    private var session: URLSession?
    private var copiedURL: URL?
    private var delivered = false

    func start(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderPathBar-download-\(UUID().uuidString).dmg")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: location, to: dest)
            copiedURL = dest
        } catch {
            deliver(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            deliver(.failure(error))
            return
        }
        if let copiedURL {
            deliver(.success(copiedURL))
        } else {
            deliver(.failure(NSError(
                domain: "FinderPathBar",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Update download did not produce a file"]
            )))
        }
    }

    private func deliver(_ result: Result<URL, Error>) {
        guard !delivered else { return }
        delivered = true
        onFinish?(result)
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: UInt32 = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + UInt32(scalar.value)
    }
    return result
}

private func escapedAppleScript(_ string: String) -> String {
    string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

private func escapedRString(_ string: String) -> String {
    string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}
