import Foundation
import AppKit

struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    let creationDate: Date?

    var displayName: String { name }

    /// Keys prefetched by `FileOperations.listDirectory` (kept lean for large folders).
    static let listingKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    /// Build from URL that already had `listingKeys` prefetched (no extra existence check).
    static func fromListedURL(_ url: URL) -> FileItem? {
        let values = try? url.resourceValues(forKeys: Set(listingKeys))
        let isDirectory = values?.isDirectory == true
        let isPackage = values?.isPackage == true
        let name = url.lastPathComponent
        guard !name.isEmpty else { return nil }
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory && !isPackage,
            isPackage: isPackage,
            isHidden: values?.isHidden == true || name.hasPrefix("."),
            fileSize: (isDirectory && !isPackage) ? nil : Int64(values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            creationDate: nil
        )
    }

    static func from(url: URL) -> FileItem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .localizedNameKey
        ])

        let isDirectory = values?.isDirectory == true
        let isPackage = values?.isPackage == true
        return FileItem(
            url: url,
            name: values?.localizedName ?? url.lastPathComponent,
            isDirectory: isDirectory && !isPackage,
            isPackage: isPackage,
            isHidden: values?.isHidden == true || url.lastPathComponent.hasPrefix("."),
            fileSize: isDirectory ? nil : Int64(values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            creationDate: values?.creationDate
        )
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var folder: String

    init(id: UUID = UUID(), name: String, path: String, folder: String = "收藏") {
        self.id = id
        self.name = name
        self.path = path
        self.folder = folder
    }
}

final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let showHidden = "showHidden"
        static let newItemTypes = "newItemTypes"
        static let bookmarks = "bookmarks"
        static let bookmarkFolderOrder = "bookmarkFolderOrder"
        static let languageChinese = "languageChinese"
        static let redirectFinder = "redirectFinderClicks"
        static let launchAtLogin = "launchAtLogin"
    }

    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: Keys.showHidden) }
        set { defaults.set(newValue, forKey: Keys.showHidden) }
    }

    /// When Dock Finder is clicked / Finder windows open, switch to NewFinder.
    var redirectFinderClicks: Bool {
        get {
            if defaults.object(forKey: Keys.redirectFinder) == nil { return true }
            return defaults.bool(forKey: Keys.redirectFinder)
        }
        set { defaults.set(newValue, forKey: Keys.redirectFinder) }
    }

    var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: Keys.launchAtLogin) == nil { return true }
            return defaults.bool(forKey: Keys.launchAtLogin)
        }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    static let defaultNewItemTypes = ["dir", "txt", "ppt", "xlsx", "docx", "R", "py"]

    var newItemTypes: [String] {
        get {
            let raw = defaults.stringArray(forKey: Keys.newItemTypes)
            if let raw {
                let lowered = raw.map { $0.lowercased() }
                // Migrate previous factory defaults, or restore proper case for current defaults.
                if lowered == ["dir", "txt", "md", "swift", "xlsx", "docx"]
                    || (lowered == Self.defaultNewItemTypes.map { $0.lowercased() }
                        && raw != Self.defaultNewItemTypes) {
                    defaults.set(Self.defaultNewItemTypes, forKey: Keys.newItemTypes)
                    return Self.defaultNewItemTypes
                }
            }
            return normalizedTypes(raw ?? Self.defaultNewItemTypes)
        }
        set { defaults.set(normalizedTypes(newValue), forKey: Keys.newItemTypes) }
    }

    var bookmarks: [Bookmark] {
        get {
            guard let data = defaults.data(forKey: Keys.bookmarks),
                  let items = try? JSONDecoder().decode([Bookmark].self, from: data) else {
                return []
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.bookmarks)
            }
        }
    }

    var bookmarkFolderOrder: [String] {
        get { defaults.stringArray(forKey: Keys.bookmarkFolderOrder) ?? [] }
        set { defaults.set(newValue, forKey: Keys.bookmarkFolderOrder) }
    }

    var preferChinese: Bool {
        get {
            if defaults.object(forKey: Keys.languageChinese) == nil { return true }
            return defaults.bool(forKey: Keys.languageChinese)
        }
        set { defaults.set(newValue, forKey: Keys.languageChinese) }
    }

    private func normalizedTypes(_ raw: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for item in raw {
            // Preserve case exactly (e.g. R vs r); only trim whitespace.
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
            if result.count >= 40 { break }
        }
        if result.isEmpty {
            return Self.defaultNewItemTypes
        }
        return result
    }
}

struct VisitRecord: Equatable {
    var url: URL
    var visitedAt: Date
}

final class NavigationHistory {
    private(set) var stack: [URL] = []
    private(set) var index: Int = -1
    /// Most-recent-first visit list for the path-bar dropdown.
    private(set) var recentVisits: [VisitRecord] = []
    private let maxRecent = 40

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < stack.count - 1 }
    var current: URL? { (index >= 0 && index < stack.count) ? stack[index] : nil }

    func navigate(to url: URL) {
        let standardized = url.standardizedFileURL
        if let current, current == standardized {
            recordRecent(standardized)
            return
        }
        if index >= 0 && index < stack.count - 1 {
            stack = Array(stack.prefix(index + 1))
        }
        stack.append(standardized)
        index = stack.count - 1
        recordRecent(standardized)
    }

    func goBack() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        recordRecent(stack[index])
        return stack[index]
    }

    func goForward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        recordRecent(stack[index])
        return stack[index]
    }

    func jump(to index: Int) -> URL? {
        guard index >= 0, index < stack.count else { return nil }
        self.index = index
        recordRecent(stack[index])
        return stack[index]
    }

    private func recordRecent(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentVisits.removeAll { $0.url.standardizedFileURL == standardized }
        recentVisits.insert(VisitRecord(url: standardized, visitedAt: Date()), at: 0)
        if recentVisits.count > maxRecent {
            recentVisits = Array(recentVisits.prefix(maxRecent))
        }
    }
}
