import AppKit
import UniformTypeIdentifiers

final class ContentViewController: NSViewController {
    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (([FileItem]) -> Void)?
    var onRenameRequest: ((FileItem) -> Void)?
    var onCommitRename: ((FileItem, String) -> Void)?

    private(set) var items: [FileItem] = []

    private var listScroll: NSScrollView!
    private var listView: NSTableView!
    private var emptyLabel: NSTextField!
    private weak var renamingField: NSTextField?
    private var renamingItem: FileItem?
    private var renamingOriginalName: String?

    /// Ordered sort keys: index 0 is primary. Shift-click adds secondary keys.
    private struct SortKey: Equatable {
        var columnID: String
        var ascending: Bool
    }
    private var sortKeys: [SortKey] = [SortKey(columnID: "name", ascending: true)]

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        emptyLabel = NSTextField(labelWithString: "文件夹为空")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        listScroll.autohidesScrollers = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(listDoubleClicked)
        table.target = self

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "名称"
        nameCol.width = 320
        nameCol.minWidth = 140
        nameCol.headerCell.alignment = .left
        table.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "修改日期"
        dateCol.width = 160
        dateCol.headerCell.alignment = .left
        table.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "大小"
        sizeCol.width = 90
        sizeCol.headerCell.alignment = .left
        table.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: .init("kind"))
        kindCol.title = "种类"
        kindCol.width = 120
        kindCol.headerCell.alignment = .left
        table.addTableColumn(kindCol)

        table.dataSource = self
        table.delegate = self
        listView = table
        listScroll.documentView = table
        updateSortIndicator()

        root.addSubview(listScroll)
        root.addSubview(emptyLabel)
        view = root

        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: root.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])

        let menu = NSMenu()
        menu.addItem(withTitle: "打开", action: #selector(contextOpen), keyEquivalent: "")
        menu.addItem(withTitle: "显示简介", action: #selector(contextGetInfo), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "重命名", action: #selector(contextRename), keyEquivalent: "")
        menu.addItem(withTitle: "移到废纸篓", action: #selector(contextTrash), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "在 NewFinder 中显示", action: #selector(contextReveal), keyEquivalent: "")
        listView.menu = menu

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    func setItems(_ items: [FileItem], alreadySortedByName: Bool = false) {
        let previousSelection = selectedItems.map(\.url.standardizedFileURL)
        emptyLabel.isHidden = !items.isEmpty
        let defaultNameSort = sortKeys == [SortKey(columnID: "name", ascending: true)]
        if alreadySortedByName, defaultNameSort {
            self.items = items
            listView.reloadData()
            updateSortIndicator()
            if !previousSelection.isEmpty {
                select(urls: previousSelection)
            }
            onSelectionChange?(selectedItems)
            return
        }
        self.items = items
        applySort(preservingSelection: false)
        if !previousSelection.isEmpty {
            select(urls: previousSelection)
        }
        onSelectionChange?(selectedItems)
    }

    /// 单击表头：按该列主排序；再点同一列切换升降序。
    /// Shift+单击：追加次要排序（多列同时排序）；已在排序链中则切换该列方向。
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let id = tableColumn.identifier.rawValue
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true

        if shift {
            if let index = sortKeys.firstIndex(where: { $0.columnID == id }) {
                sortKeys[index].ascending.toggle()
            } else {
                sortKeys.append(SortKey(columnID: id, ascending: true))
            }
        } else if sortKeys.count == 1, sortKeys[0].columnID == id {
            sortKeys[0].ascending.toggle()
        } else {
            sortKeys = [SortKey(columnID: id, ascending: true)]
        }
        applySort(preservingSelection: true)
    }

    private func applySort(preservingSelection: Bool) {
        let selectedURLs = preservingSelection ? selectedItems.map(\.url) : []
        let keys = sortKeys
        let snapshot = items

        let finish: ([FileItem]) -> Void = { [weak self] sorted in
            guard let self else { return }
            self.items = sorted
            self.listView.reloadData()
            self.updateSortIndicator()
            if preservingSelection, !selectedURLs.isEmpty {
                self.select(urls: selectedURLs)
            }
            self.onSelectionChange?(self.selectedItems)
        }

        if snapshot.count > 8_000 {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let sorted = self.sortedItems(snapshot, keys: keys)
                DispatchQueue.main.async { finish(sorted) }
            }
        } else {
            finish(sortedItems(snapshot, keys: keys))
        }
    }

    private func sortedItems(_ items: [FileItem], keys: [SortKey]) -> [FileItem] {
        items.sorted { lhs, rhs in
            for key in keys {
                let result = compare(lhs, rhs, by: key.columnID)
                if result != .orderedSame {
                    return key.ascending
                        ? result == .orderedAscending
                        : result == .orderedDescending
                }
            }
            return false
        }
    }

    private func compare(_ lhs: FileItem, _ rhs: FileItem, by columnID: String) -> ComparisonResult {
        switch columnID {
        case "date":
            let l = lhs.modificationDate ?? .distantPast
            let r = rhs.modificationDate ?? .distantPast
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        case "size":
            let l = lhs.isDirectory ? Int64.min : (lhs.fileSize ?? 0)
            let r = rhs.isDirectory ? Int64.min : (rhs.fileSize ?? 0)
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        case "kind":
            return kindString(for: lhs).localizedStandardCompare(kindString(for: rhs))
        default:
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory ? .orderedAscending : .orderedDescending
            }
            return lhs.name.localizedStandardCompare(rhs.name)
        }
    }

    private func updateSortIndicator() {
        let titles: [String: String] = [
            "name": "名称",
            "date": "修改日期",
            "size": "大小",
            "kind": "种类"
        ]
        let ascending = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        let descending = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)

        for column in listView.tableColumns {
            let id = column.identifier.rawValue
            let base = titles[id] ?? column.title
            if let index = sortKeys.firstIndex(where: { $0.columnID == id }) {
                let key = sortKeys[index]
                listView.setIndicatorImage(key.ascending ? ascending : descending, in: column)
                // 多列时在标题上标优先级 1、2、3…
                column.title = sortKeys.count > 1 ? "\(base) \(index + 1)" : base
            } else {
                listView.setIndicatorImage(nil, in: column)
                column.title = base
            }
        }
    }

    var selectedItems: [FileItem] {
        listView.selectedRowIndexes.compactMap { idx in
            guard items.indices.contains(idx) else { return nil }
            return items[idx]
        }
    }

    func select(urls: [URL]) {
        let set = Set(urls.map { $0.standardizedFileURL })
        var indexes = IndexSet()
        for (idx, item) in items.enumerated() where set.contains(item.url.standardizedFileURL) {
            indexes.insert(idx)
        }
        listView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first {
            listView.scrollRowToVisible(first)
        }
        // Inactive (gray) selection happens when the table is not first responder.
        if !indexes.isEmpty {
            view.window?.makeKeyAndOrderFront(nil)
            view.window?.makeFirstResponder(listView)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.view.window?.makeFirstResponder(self.listView)
            }
        }
        onSelectionChange?(selectedItems)
    }

    func selectAll() {
        listView.selectAll(nil)
        onSelectionChange?(selectedItems)
    }

    func beginInlineRename(_ item: FileItem) {
        guard let row = items.firstIndex(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) else {
            return
        }
        listView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        listView.scrollRowToVisible(row)
        listView.layoutSubtreeIfNeeded()

        guard let cell = listView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }

        endInlineRename(commit: false)

        renamingItem = item
        renamingOriginalName = item.name
        renamingField = field

        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .default
        field.delegate = self
        field.target = self
        field.action = #selector(nameFieldAction(_:))
        field.stringValue = item.name

        view.window?.makeFirstResponder(field)
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.renamingField === field else { return }
            self.selectRenameRange(in: field, for: item)
        }
    }

    private func selectRenameRange(in field: NSTextField, for item: FileItem) {
        let name = item.name as NSString
        let length: Int
        if !item.isDirectory && !item.isPackage {
            let ext = name.pathExtension
            if !ext.isEmpty, name.length > ext.count + 1 {
                length = name.length - ext.count - 1
            } else {
                length = name.length
            }
        } else {
            length = name.length
        }
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
    }

    private func endInlineRename(commit: Bool) {
        guard let field = renamingField else { return }
        let item = renamingItem
        let original = renamingOriginalName
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        field.delegate = nil
        field.target = nil
        field.action = nil
        field.isEditable = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none

        renamingField = nil
        renamingItem = nil
        renamingOriginalName = nil

        if commit, let item, let original {
            if !newName.isEmpty, newName != original {
                onCommitRename?(item, newName)
            } else {
                field.stringValue = original
            }
        } else if let original {
            field.stringValue = original
        }

        if view.window?.firstResponder === field || view.window?.firstResponder is NSText {
            view.window?.makeFirstResponder(listView)
        }
    }

    @objc private func nameFieldAction(_ sender: NSTextField) {
        endInlineRename(commit: true)
    }

    @objc private func listDoubleClicked() {
        let row = listView.clickedRow
        guard row >= 0, items.indices.contains(row) else { return }
        onOpen?(items[row])
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard view.window?.isKeyWindow == true else { return event }
        if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
            return event
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            if let item = selectedItems.first {
                onOpen?(item)
                return nil
            }
        }
        if event.keyCode == 51 {
            NotificationCenter.default.post(name: .contentRequestTrash, object: self)
            return nil
        }
        if event.keyCode == 113 {
            if let item = selectedItems.first {
                onRenameRequest?(item)
                return nil
            }
        }
        return event
    }

    @objc private func contextOpen() {
        selectedItems.forEach { onOpen?($0) }
    }

    @objc private func contextRename() {
        if let item = selectedItems.first {
            onRenameRequest?(item)
        }
    }

    @objc private func contextTrash() {
        NotificationCenter.default.post(name: .contentRequestTrash, object: self)
    }

    @objc private func contextReveal() {
        FileOperations.revealInFinder(selectedItems.map(\.url))
    }

    @objc private func contextGetInfo() {
        guard let item = selectedItems.first else { return }
        let values = try? item.url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ])
        let alert = NSAlert()
        alert.messageText = item.name
        let size: String
        if item.isDirectory {
            size = "文件夹"
        } else {
            let bytes = values?.fileSize.map(Int64.init) ?? item.fileSize ?? 0
            size = FileOperations.formatFileSize(bytes)
        }
        alert.informativeText = """
        路径：\(item.url.path)
        大小：\(size)
        修改：\(FileOperations.formatDate(values?.contentModificationDate ?? item.modificationDate))
        创建：\(FileOperations.formatDate(values?.creationDate ?? item.creationDate))
        """
        alert.runModal()
    }
}

extension Notification.Name {
    static let contentRequestTrash = Notification.Name("NewFinder.contentRequestTrash")
}

extension ContentViewController: NSTableViewDataSource, NSTableViewDelegate {
    private static var iconCache: [String: NSImage] = [:]
    private static let folderIcon: NSImage = {
        let image = NSWorkspace.shared.icon(for: .folder)
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }()

    private static func cachedIcon(for item: FileItem) -> NSImage {
        if item.isDirectory {
            return folderIcon
        }
        let ext = item.url.pathExtension.lowercased()
        let key = ext.isEmpty ? "._file" : ext
        if let cached = iconCache[key] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 16, height: 16)
        if iconCache.count < 256 {
            iconCache[key] = sized
        }
        return sized
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let id = tableColumn?.identifier ?? .init("name")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeListCell(id: id)

        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = item.name
            cell.imageView?.image = Self.cachedIcon(for: item)
        case "date":
            cell.textField?.stringValue = FileOperations.formatDate(item.modificationDate)
            cell.imageView?.image = nil
        case "size":
            cell.textField?.stringValue = item.isDirectory ? "--" : FileOperations.formatFileSize(item.fileSize)
            cell.imageView?.image = nil
        case "kind":
            cell.textField?.stringValue = kindString(for: item)
            cell.imageView?.image = nil
        default:
            break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedItems)
    }

    private func makeListCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = .left
        cell.addSubview(field)
        cell.textField = field

        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    private func kindString(for item: FileItem) -> String {
        if item.isDirectory { return "文件夹" }
        if item.isPackage { return "应用程序" }
        let ext = item.url.pathExtension
        if ext.isEmpty { return "文稿" }
        return ext.lowercased() + " 文稿"
    }
}

extension ContentViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard renamingField != nil, obj.object as AnyObject? === renamingField else { return }
        let movement = obj.userInfo?["NSTextMovement"] as? Int ?? 0
        let cancelled = movement == NSTextMovement.cancel.rawValue
        endInlineRename(commit: !cancelled)
    }
}
