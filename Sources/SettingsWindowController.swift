import AppKit

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()
    static let didChangeNotification = Notification.Name("NewFinder.settingsChanged")

    private let settings = AppSettings.shared
    private var typeFields: [NSTextField] = []
    private var typeRowsStack: NSStackView!
    private var redirectFinderCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewFinder 设置"
        window.center()
        super.init(window: window)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reloadValues()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared.registerAsDefaultFolderViewer()
    }

    private func configure() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "常规")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)

        redirectFinderCheckbox = NSButton(
            checkboxWithTitle: "拦截系统 Finder，改用 NewFinder",
            target: self,
            action: #selector(toggleRedirectFinder)
        )
        stack.addArrangedSubview(redirectFinderCheckbox)

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "登录时打开 NewFinder（便于持续拦截）",
            target: self,
            action: #selector(toggleLaunchAtLogin)
        )
        stack.addArrangedSubview(launchAtLoginCheckbox)

        let redirectHint = NSTextField(wrappingLabelWithString: """
        NewFinder 在菜单栏显示图标（不占用 Dock）。\
        会尽量接管：打开文件夹、在 Finder 中显示。\
        即使退出 NewFinder，后台监视仍会在点击 Dock Finder 时自动拉起。\
        首次需在「隐私与安全性 → 自动化」允许控制 Finder。
        """)
        redirectHint.textColor = .secondaryLabelColor
        redirectHint.font = .systemFont(ofSize: 11)
        redirectHint.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(redirectHint)

        let newTitle = NSTextField(labelWithString: "快捷新建类型（dir = 文件夹；大小写按原样保留）")
        newTitle.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(newTitle)

        typeRowsStack = NSStackView()
        typeRowsStack.orientation = .vertical
        typeRowsStack.alignment = .leading
        typeRowsStack.spacing = 6
        typeRowsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = typeRowsStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        stack.addArrangedSubview(scroll)

        let addButton = NSButton(title: "添加类型", target: self, action: #selector(addTypeRow))
        addButton.bezelStyle = .rounded
        stack.addArrangedSubview(addButton)

        let hint = NSTextField(wrappingLabelWithString: "例如：dir、txt、ppt、xlsx、docx、R、py。工具栏 ★ 可编辑收藏；⌘L 编辑路径。显示隐藏文件请用菜单「显示」。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(hint)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            typeRowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
    }

    private func reloadValues() {
        redirectFinderCheckbox.state = settings.redirectFinderClicks ? .on : .off
        launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off
        rebuildTypeRows(with: settings.newItemTypes)
    }

    private func rebuildTypeRows(with types: [String]) {
        typeRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        typeFields.removeAll()
        let list = types.isEmpty ? AppSettings.defaultNewItemTypes : types
        for value in list {
            appendTypeRow(value: value, focus: false)
        }
        layoutTypeRows()
    }

    private func appendTypeRow(value: String, focus: Bool) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let field = NSTextField()
        field.font = .systemFont(ofSize: 12)
        field.stringValue = value
        field.placeholderString = "扩展名或 dir"
        field.delegate = self
        field.target = self
        field.action = #selector(typesChanged)
        field.widthAnchor.constraint(equalToConstant: 120).isActive = true
        typeFields.append(field)

        let remove = NSButton(title: "删除", target: self, action: #selector(removeTypeRow(_:)))
        remove.bezelStyle = .rounded
        remove.setButtonType(.momentaryPushIn)

        row.addArrangedSubview(field)
        row.addArrangedSubview(remove)
        typeRowsStack.addArrangedSubview(row)

        if focus {
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(field)
            }
        }
    }

    private func layoutTypeRows() {
        typeRowsStack.layoutSubtreeIfNeeded()
        let width = typeRowsStack.enclosingScrollView?.contentView.bounds.width
            ?? typeRowsStack.fittingSize.width
        let height = max(typeRowsStack.fittingSize.height, 1)
        typeRowsStack.setFrameSize(NSSize(width: max(width, 400), height: height))
    }

    @objc private func addTypeRow() {
        guard typeFields.count < 40 else { return }
        appendTypeRow(value: "", focus: true)
        layoutTypeRows()
        typesChanged()
    }

    @objc private func removeTypeRow(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView else { return }
        if let field = row.arrangedSubviews.first as? NSTextField,
           let idx = typeFields.firstIndex(of: field) {
            typeFields.remove(at: idx)
        }
        row.removeFromSuperview()
        if typeFields.isEmpty {
            appendTypeRow(value: "dir", focus: false)
        }
        layoutTypeRows()
        typesChanged()
    }

    @objc private func toggleRedirectFinder() {
        settings.redirectFinderClicks = redirectFinderCheckbox.state == .on
        AppDelegate.shared.updateFinderWindowPollTimer()
        notifyChange()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin = launchAtLoginCheckbox.state == .on
        AppDelegate.shared.applyLaunchAtLoginSetting()
        notifyChange()
    }

    @objc private func typesChanged() {
        settings.newItemTypes = typeFields.map(\.stringValue)
        notifyChange()
    }

    func controlTextDidChange(_ obj: Notification) {
        typesChanged()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
