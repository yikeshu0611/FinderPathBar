import AppKit

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()
    static let didChangeNotification = Notification.Name("NewFinder.settingsChanged")

    private let settings = AppSettings.shared
    private var typeFields: [NSTextField] = []
    private var typeRowsStack: NSStackView!
    private var redirectFinderCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var versionLabel: NSTextField!
    private var updateStatusLabel: NSTextField!
    private var checkUpdateButton: NSButton!
    private var downloadUpdateButton: NSButton!
    private var pendingRelease: UpdateChecker.ReleaseInfo?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
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

        let updateTitle = NSTextField(labelWithString: "更新")
        updateTitle.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(updateTitle)

        versionLabel = NSTextField(labelWithString: "当前版本：—")
        versionLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(versionLabel)

        updateStatusLabel = NSTextField(wrappingLabelWithString: "从 GitHub 检查 NewFinder 新版本。")
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(updateStatusLabel)

        let updateRow = NSStackView()
        updateRow.orientation = .horizontal
        updateRow.spacing = 8
        updateRow.alignment = .centerY
        checkUpdateButton = NSButton(title: "检查更新", target: self, action: #selector(checkForUpdates))
        checkUpdateButton.bezelStyle = .rounded
        downloadUpdateButton = NSButton(title: "下载更新", target: self, action: #selector(downloadUpdate))
        downloadUpdateButton.bezelStyle = .rounded
        downloadUpdateButton.isHidden = true
        updateRow.addArrangedSubview(checkUpdateButton)
        updateRow.addArrangedSubview(downloadUpdateButton)
        stack.addArrangedSubview(updateRow)

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
        versionLabel.stringValue = "当前版本：\(UpdateChecker.currentVersion)"
        rebuildTypeRows(with: settings.newItemTypes)
    }

    @objc private func checkForUpdates() {
        checkUpdateButton.isEnabled = false
        downloadUpdateButton.isHidden = true
        pendingRelease = nil
        updateStatusLabel.stringValue = "正在检查更新…"

        UpdateChecker.fetchLatest { [weak self] result in
            guard let self else { return }
            self.checkUpdateButton.isEnabled = true
            switch result {
            case .failure:
                self.updateStatusLabel.stringValue = "检查失败，请确认网络连接后重试。"
            case .success(let release):
                let current = UpdateChecker.currentVersion
                if UpdateChecker.isVersion(release.version, newerThan: current) {
                    self.pendingRelease = release
                    self.updateStatusLabel.stringValue = "发现新版本 \(release.version)（当前 \(current)）。"
                    self.downloadUpdateButton.isHidden = false
                } else {
                    self.updateStatusLabel.stringValue = "已是最新版本（\(current)）。"
                }
            }
        }
    }

    @objc private func downloadUpdate() {
        guard let release = pendingRelease else { return }
        checkUpdateButton.isEnabled = false
        downloadUpdateButton.isEnabled = false
        updateStatusLabel.stringValue = "正在下载 \(release.version)…"

        UpdateChecker.download(release) { [weak self] result in
            guard let self else { return }
            self.checkUpdateButton.isEnabled = true
            self.downloadUpdateButton.isEnabled = true
            switch result {
            case .failure:
                self.updateStatusLabel.stringValue = "下载失败，请稍后重试或在 GitHub Releases 手动下载。"
            case .success(let dmgURL):
                NSWorkspace.shared.open(dmgURL)
                self.updateStatusLabel.stringValue = "已下载并打开安装包，请将 NewFinder 拖入「应用程序」完成更新。"
                let alert = NSAlert()
                alert.messageText = "更新包已下载"
                alert.informativeText = """
                已打开 \(dmgURL.lastPathComponent)。
                将 NewFinder 拖入「应用程序」文件夹覆盖旧版本，然后重新打开即可。
                """
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
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
