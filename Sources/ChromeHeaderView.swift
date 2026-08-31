import AppKit

final class BrowserTab {
    let id = UUID()
    var directory: URL
    let history = NavigationHistory()

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
        history.navigate(to: self.directory)
    }

    var title: String {
        if directory.path == "/" { return "Macintosh HD" }
        let name = directory.lastPathComponent
        return name.isEmpty ? directory.path : name
    }
}

/// Chrome-like header: tab strip on top, tools below.
enum TabInsertSide {
    case left, right
}

enum TabCloseScope {
    case thisTab, left, right, others
}

final class ChromeHeaderView: NSView {
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewTabRelative: ((UUID, TabInsertSide) -> Void)?
    var onCloseTabsRelative: ((UUID, TabCloseScope) -> Void)?
    var onDetachTab: ((UUID, NSPoint) -> Void)?

    private let tabRow = NSView()
    private let tabStrip = TabStripView()
    private let toolRow = NSStackView()
    private var searchField: NSSearchField!
    private weak var showHiddenButton: NSButton?
    private let bookmarkFolderStack = NSStackView()
    private weak var actionTarget: AnyObject?

    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTabID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configure()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
        rebuildTabs()
    }

    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.82, alpha: 1)).cgColor
        toolRow.layer?.backgroundColor = (dark
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.94, alpha: 1)).cgColor
        tabRow.layer?.backgroundColor = (dark
            ? NSColor(calibratedWhite: 0.15, alpha: 1)
            : NSColor(calibratedWhite: 0.78, alpha: 1)).cgColor
    }

    func bind(target: AnyObject) {
        actionTarget = target
        rebuildTools()
    }

    func setTabs(_ tabs: [BrowserTab], activeID: UUID?) {
        self.tabs = tabs
        self.activeTabID = activeID
        rebuildTabs()
    }

    func rebuildNewItemTypes(_ types: [String]) {
        rebuildTools(types: types)
    }

    func syncShowHiddenFilesButton(_ showHidden: Bool) {
        guard let button = showHiddenButton else { return }
        let symbol = showHidden ? "eye" : "eye.slash"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: showHidden ? "隐藏隐藏项" : "显示隐藏项")
        button.image?.isTemplate = true
        button.contentTintColor = showHidden ? .controlAccentColor : .labelColor
        button.toolTip = showHidden ? "隐藏隐藏项 (⌘.)" : "显示隐藏项 (⌘.)"
    }

    var searchFieldView: NSSearchField { searchField }

    private func configure() {
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        tabRow.wantsLayer = true

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelectTab = { [weak self] id in self?.onSelectTab?(id) }
        tabStrip.onCloseTab = { [weak self] id in self?.onCloseTab?(id) }
        tabStrip.onNewTab = { [weak self] in self?.onNewTab?() }
        tabStrip.onDetachTab = { [weak self] id, screenPoint in self?.onDetachTab?(id, screenPoint) }
        tabStrip.onContextAction = { [weak self] id, action in
            guard let self else { return }
            switch action {
            case .newLeft: self.onNewTabRelative?(id, .left)
            case .newRight: self.onNewTabRelative?(id, .right)
            case .close: self.onCloseTabsRelative?(id, .thisTab)
            case .closeLeft: self.onCloseTabsRelative?(id, .left)
            case .closeRight: self.onCloseTabsRelative?(id, .right)
            case .closeOthers: self.onCloseTabsRelative?(id, .others)
            }
        }

        toolRow.orientation = .horizontal
        toolRow.spacing = 2
        toolRow.alignment = .centerY
        toolRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        toolRow.wantsLayer = true

        addSubview(tabRow)
        tabRow.addSubview(tabStrip)
        addSubview(toolRow)

        NSLayoutConstraint.activate([
            tabRow.topAnchor.constraint(equalTo: topAnchor),
            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: 32),

            // Tabs start after traffic lights; + sits right after the last tab (inside strip).
            tabStrip.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor, constant: 78),
            tabStrip.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor, constant: -10),
            tabStrip.topAnchor.constraint(equalTo: tabRow.topAnchor, constant: 2),
            tabStrip.bottomAnchor.constraint(equalTo: tabRow.bottomAnchor),

            toolRow.topAnchor.constraint(equalTo: tabRow.bottomAnchor),
            toolRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolRow.heightAnchor.constraint(equalToConstant: 30)
        ])

        searchField = NSSearchField()
        searchField.placeholderString = "搜索"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true
    }

    private func rebuildTabs() {
        let items: [TabStripView.Item] = tabs.map { tab in
            TabStripView.Item(
                id: tab.id,
                title: tab.title,
                icon: NSWorkspace.shared.icon(forFile: tab.directory.path),
                isActive: tab.id == activeTabID,
                canClose: tabs.count > 1
            )
        }
        tabStrip.setItems(items)
    }

    private func rebuildTools(types: [String]? = nil) {
        toolRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let target = actionTarget else { return }

        toolRow.addArrangedSubview(iconButton("chevron.left", tip: "后退", action: #selector(BrowserWindowController.goBack(_:)), target: target))
        toolRow.addArrangedSubview(iconButton("chevron.right", tip: "前进", action: #selector(BrowserWindowController.goForward(_:)), target: target))
        toolRow.addArrangedSubview(iconButton("chevron.up", tip: "上层文件夹", action: #selector(BrowserWindowController.goEnclosingFolder(_:)), target: target))
        toolRow.addArrangedSubview(separator())
        toolRow.addArrangedSubview(makeNewMenuButton(types: types ?? AppSettings.shared.newItemTypes, target: target))
        bookmarkFolderStack.orientation = .horizontal
        bookmarkFolderStack.spacing = 4
        bookmarkFolderStack.alignment = .centerY
        bookmarkFolderStack.setContentHuggingPriority(.required, for: .horizontal)
        toolRow.addArrangedSubview(bookmarkFolderStack)
        toolRow.addArrangedSubview(flexibleSpace())

        let fileActionsRow = NSStackView()
        fileActionsRow.orientation = .horizontal
        fileActionsRow.spacing = 2
        fileActionsRow.alignment = .centerY
        fileActionsRow.translatesAutoresizingMaskIntoConstraints = false
        fileActionsRow.addArrangedSubview(iconButton("pencil", tip: "重命名 (F2)", action: #selector(BrowserWindowController.rename(_:)), target: target))
        fileActionsRow.addArrangedSubview(iconButton("doc.on.doc", tip: "拷贝", action: #selector(BrowserWindowController.copy(_:)), target: target))
        fileActionsRow.addArrangedSubview(iconButton("scissors", tip: "剪切", action: #selector(BrowserWindowController.cut(_:)), target: target))
        fileActionsRow.addArrangedSubview(iconButton("clipboard", tip: "粘贴", action: #selector(BrowserWindowController.paste(_:)), target: target))
        fileActionsRow.addArrangedSubview(iconButton("trash", tip: "移到废纸篓", action: #selector(BrowserWindowController.moveToTrash(_:)), target: target))
        let hiddenBtn = iconButton("eye.slash", tip: "显示隐藏项 (⌘.)", action: #selector(BrowserWindowController.toggleHiddenFiles(_:)), target: target)
        showHiddenButton = hiddenBtn
        syncShowHiddenFilesButton(AppSettings.shared.showHiddenFiles)
        fileActionsRow.addArrangedSubview(hiddenBtn)
        toolRow.addArrangedSubview(fileActionsRow)
        toolRow.addArrangedSubview(flexibleSpace())

        searchField.target = target
        searchField.action = #selector(BrowserWindowController.searchChanged(_:))
        toolRow.addArrangedSubview(searchField)
        toolRow.addArrangedSubview(iconButton("gearshape", tip: "设置", action: #selector(BrowserWindowController.openSettings(_:)), target: target))
    }

    var bookmarkFoldersContainer: NSStackView { bookmarkFolderStack }

    private func makeNewMenuButton(types: [String], target: AnyObject) -> NSButton {
        let button = NewMenuButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.title = "New"
        button.attributedTitle = NSAttributedString(
            string: "New",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(calibratedWhite: 0.32, alpha: 1)
            ]
        )
        button.toolTip = "新建文件夹或文件"
        button.focusRingType = .none
        button.contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setButtonType(.momentaryPushIn)
        button.actionTarget = target
        button.items = types.enumerated().map { index, type in
            let isDir = type.lowercased() == "dir"
            return NewMenuButton.Item(
                title: isDir ? "文件夹" : type,
                tag: index,
                toolTip: isDir ? "新建文件夹" : "新建 .\(type) 文件（按住 Option 并打开）"
            )
        }
        return button
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = target
        button.action = action
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        return view
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 62)
    }
}

// MARK: - Tab strip (single view owns all hit-testing — Chrome-like)

final class TabStripView: NSView {
    struct Item {
        let id: UUID
        let title: String
        let icon: NSImage?
        let isActive: Bool
        let canClose: Bool
    }

    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onDetachTab: ((UUID, NSPoint) -> Void)?
    var onContextAction: ((UUID, TabContextAction) -> Void)?

    enum TabContextAction {
        case newLeft, newRight, close, closeLeft, closeRight, closeOthers
    }

    private var items: [Item] = []
    private var tabFrames: [UUID: NSRect] = [:]
    private var closeFrames: [UUID: NSRect] = [:]
    private var plusFrame: NSRect = .zero
    private var hoveredID: UUID?
    private var plusHovered = false
    private var tracking: NSTrackingArea?
    private var contextTabID: UUID?

    private let tabHeight: CGFloat = 30
    private let tabMinWidth: CGFloat = 120
    private let tabMaxWidth: CGFloat = 180
    private let overlap: CGFloat = 14
    private let corner: CGFloat = 8
    private let ear: CGFloat = 8
    private let plusSize: CGFloat = 22
    private let plusGap: CGFloat = 4

    func setItems(_ items: [Item]) {
        self.items = items
        hoveredID = nil
        plusHovered = false
        needsDisplay = true
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        recalculateFrames()
    }

    private func recalculateFrames() {
        tabFrames.removeAll()
        closeFrames.removeAll()
        plusFrame = .zero
        guard !items.isEmpty else {
            // Still show + at leading edge when empty (shouldn't happen)
            let y = bounds.height - tabHeight + (tabHeight - plusSize) / 2
            plusFrame = NSRect(x: 0, y: y, width: plusSize, height: plusSize)
            return
        }

        let count = CGFloat(items.count)
        // Reserve room for + after last tab
        let reserved = plusGap + plusSize + 4
        let available = max(0, bounds.width - reserved)

        var width = tabMaxWidth
        if count > 1 {
            let totalIfMax = tabMaxWidth * count - overlap * (count - 1)
            if totalIfMax > available {
                width = max(tabMinWidth, (available + overlap * (count - 1)) / count)
            }
        } else {
            width = min(tabMaxWidth, max(tabMinWidth, available))
        }

        var x: CGFloat = 0
        let y = bounds.height - tabHeight
        for item in items {
            let frame = NSRect(x: x, y: y, width: width, height: tabHeight)
            tabFrames[item.id] = frame
            closeFrames[item.id] = NSRect(
                x: frame.maxX - 28,
                y: frame.midY - 8,
                width: 16,
                height: 16
            )
            x += width - overlap
        }

        // + sits immediately to the right of the last tab (Chrome style)
        let lastMaxX = (items.last.flatMap { tabFrames[$0.id]?.maxX }) ?? 0
        let plusY = y + (tabHeight - plusSize) / 2
        plusFrame = NSRect(x: lastMaxX + plusGap - overlap / 2, y: plusY, width: plusSize, height: plusSize)
        // Keep + inside strip
        if plusFrame.maxX > bounds.width {
            plusFrame.origin.x = max(0, bounds.width - plusSize)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        recalculateFrames()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let ordered = items.sorted { a, b in
            if a.isActive != b.isActive { return !a.isActive && b.isActive }
            return false
        }

        for item in ordered {
            guard let frame = tabFrames[item.id] else { continue }
            let isHovered = hoveredID == item.id
            let fill: NSColor
            if item.isActive {
                fill = dark ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
            } else if isHovered {
                fill = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
            } else {
                fill = dark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.80, alpha: 1)
            }

            let path = chromeTabPath(in: frame, corner: corner, ear: ear)
            fill.setFill()
            path.fill()

            let iconRect = NSRect(x: frame.minX + 12, y: frame.midY - 7, width: 14, height: 14)
            if let icon = item.icon {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }

            let titleRect = NSRect(
                x: iconRect.maxX + 6,
                y: frame.minY,
                width: max(0, frame.maxX - 34 - (iconRect.maxX + 6)),
                height: frame.height
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleColor = dark
                ? NSColor(calibratedWhite: 0.82, alpha: 1)
                : NSColor(calibratedWhite: 0.32, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: item.isActive ? .medium : .regular),
                .foregroundColor: titleColor,
                .paragraphStyle: paragraph
            ]
            let titleSize = (item.title as NSString).size(withAttributes: attrs)
            let textY = frame.minY + (frame.height - titleSize.height) / 2
            (item.title as NSString).draw(
                in: NSRect(x: titleRect.minX, y: textY, width: titleRect.width, height: titleSize.height),
                withAttributes: attrs
            )

            if item.canClose, let closeRect = closeFrames[item.id] {
                let xAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let x = "✕" as NSString
                let xSize = x.size(withAttributes: xAttrs)
                x.draw(
                    at: NSPoint(
                        x: closeRect.midX - xSize.width / 2,
                        y: closeRect.midY - xSize.height / 2
                    ),
                    withAttributes: xAttrs
                )
            }
        }

        // New-tab + immediately after last tab
        if !plusFrame.isEmpty {
            if plusHovered {
                let bg = dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
                bg.setFill()
                NSBezierPath(roundedRect: plusFrame, xRadius: plusSize / 2, yRadius: plusSize / 2).fill()
            }
            let plusAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let plus = "+" as NSString
            let plusTextSize = plus.size(withAttributes: plusAttrs)
            plus.draw(
                at: NSPoint(
                    x: plusFrame.midX - plusTextSize.width / 2,
                    y: plusFrame.midY - plusTextSize.height / 2
                ),
                withAttributes: plusAttrs
            )
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if plusFrame.insetBy(dx: -2, dy: -2).contains(point) {
            onNewTab?()
            return
        }

        var seen = Set<UUID>()
        let ordered = (items.filter(\.isActive) + items.filter { !$0.isActive }.reversed())
            .filter { seen.insert($0.id).inserted }

        for item in ordered {
            guard let frame = tabFrames[item.id] else { continue }
            let path = chromeTabPath(in: frame, corner: corner, ear: ear)
            guard path.contains(point) else { continue }

            if item.canClose, let closeRect = closeFrames[item.id], closeRect.insetBy(dx: -3, dy: -3).contains(point) {
                onCloseTab?(item.id)
                return
            }

            // Triple-click detaches the tab into a new NewFinder window.
            if event.clickCount >= 3 {
                onDetachTab?(item.id, NSEvent.mouseLocation)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                return
            }

            onSelectTab?(item.id)
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var seen = Set<UUID>()
        let ordered = (items.filter(\.isActive) + items.filter { !$0.isActive }.reversed())
            .filter { seen.insert($0.id).inserted }

        guard let item = ordered.first(where: { tab in
            guard let frame = tabFrames[tab.id] else { return false }
            return chromeTabPath(in: frame, corner: corner, ear: ear).contains(point)
        }) else { return }

        contextTabID = item.id
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let newRight = menu.addItem(withTitle: "在右侧新增标签页", action: #selector(contextNewRight), keyEquivalent: "")
        newRight.target = self
        let newLeft = menu.addItem(withTitle: "在左侧新增标签页", action: #selector(contextNewLeft), keyEquivalent: "")
        newLeft.target = self
        menu.addItem(.separator())

        let close = menu.addItem(withTitle: "关闭", action: #selector(contextClose), keyEquivalent: "")
        close.target = self
        close.isEnabled = items.count > 1

        let closeLeft = menu.addItem(withTitle: "关闭左侧标签页", action: #selector(contextCloseLeft), keyEquivalent: "")
        closeLeft.target = self
        closeLeft.isEnabled = index > 0

        let closeRight = menu.addItem(withTitle: "关闭右侧标签页", action: #selector(contextCloseRight), keyEquivalent: "")
        closeRight.target = self
        closeRight.isEnabled = index < items.count - 1

        let closeOthers = menu.addItem(withTitle: "关闭其他标签页", action: #selector(contextCloseOthers), keyEquivalent: "")
        closeOthers.target = self
        closeOthers.isEnabled = items.count > 1

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextNewRight() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .newRight)
    }

    @objc private func contextNewLeft() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .newLeft)
    }

    @objc private func contextClose() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .close)
    }

    @objc private func contextCloseLeft() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .closeLeft)
    }

    @objc private func contextCloseRight() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .closeRight)
    }

    @objc private func contextCloseOthers() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .closeOthers)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        var dirty = false
        if hoveredID != nil { hoveredID = nil; dirty = true }
        if plusHovered { plusHovered = false; dirty = true }
        if dirty { needsDisplay = true }
    }

    private func updateHover(at point: NSPoint) {
        let newPlus = plusFrame.insetBy(dx: -2, dy: -2).contains(point)
        var newHover: UUID?
        if !newPlus {
            let ordered = items.filter(\.isActive) + items.filter { !$0.isActive }.reversed()
            for item in ordered {
                guard let frame = tabFrames[item.id] else { continue }
                if chromeTabPath(in: frame, corner: corner, ear: ear).contains(point) {
                    newHover = item.id
                    break
                }
            }
        }
        if newHover != hoveredID || newPlus != plusHovered {
            hoveredID = newHover
            plusHovered = newPlus
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func chromeTabPath(in rect: NSRect, corner: CGFloat, ear: CGFloat) -> NSBezierPath {
        let r = min(corner, rect.width / 2, rect.height / 2)
        let e = min(ear, rect.width / 4, rect.height)
        let path = NSBezierPath()

        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rect.minX + e, y: rect.maxY - e),
            controlPoint1: NSPoint(x: rect.minX + e * 0.45, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.minX + e, y: rect.maxY - e * 0.55)
        )
        path.line(to: NSPoint(x: rect.minX + e, y: rect.minY + r))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + e + r, y: rect.minY + r),
            radius: r,
            startAngle: 180,
            endAngle: 270,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.maxX - e - r, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - e - r, y: rect.minY + r),
            radius: r,
            startAngle: 270,
            endAngle: 0,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.maxX - e, y: rect.maxY - e))
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.maxX - e, y: rect.maxY - e * 0.55),
            controlPoint2: NSPoint(x: rect.maxX - e * 0.45, y: rect.maxY)
        )
        path.close()
        return path
    }
}

/// Same interaction model as bookmark-folder chips: mouseUp → system NSMenu below the button.
final class NewMenuButton: NSButton {
    struct Item {
        let title: String
        let tag: Int
        let toolTip: String
    }

    var items: [Item] = []
    weak var actionTarget: AnyObject?

    override func mouseDown(with event: NSEvent) {
        // Defer until mouseUp so the same event doesn't select a menu item.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showMenu()
        }
    }

    private func showMenu() {
        guard !items.isEmpty else { return }

        let menu = NSMenu()
        let itemFont = NSFont.systemFont(ofSize: 13)
        let rowWidth = max(
            72,
            ceil((items.map { ($0.title as NSString).size(withAttributes: [.font: itemFont]).width }.max() ?? 0) + 24)
        )

        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let row = BookmarkMenuRowView(
                title: item.title,
                path: item.toolTip,
                font: itemFont,
                width: rowWidth
            )
            let tag = item.tag
            row.onOpen = { [weak self, weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let self else { return }
                    let proxy = NSMenuItem()
                    proxy.tag = tag
                    _ = self.actionTarget?.perform(
                        #selector(BrowserWindowController.newItemMenuClicked(_:)),
                        with: proxy
                    )
                }
            }
            menuItem.view = row
            menu.addItem(menuItem)
        }

        // Same anchor as bookmark-folder menus.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
