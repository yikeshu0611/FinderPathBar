import Foundation
import AppKit

enum FileOperations {
    static let pasteboardType = NSPasteboard.PasteboardType("com.zhangjing.NewFinder.cutURLs")

    static func listDirectory(_ url: URL, showHidden: Bool) -> [FileItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: FileItem.listingKeys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for fileURL in urls {
            if let item = FileItem.fromListedURL(fileURL) {
                items.append(item)
            }
        }

        // Folders first, then name (Finder-like). Done here so UI can skip a second full sort
        // when the default name sort is active.
        items.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return items
    }

    static func uniqueURL(in directory: URL, baseName: String, extensionName: String?) -> URL {
        let fm = FileManager.default
        var index = 0
        while true {
            let name: String
            if let ext = extensionName, !ext.isEmpty {
                let suffix = index == 0 ? "" : " \(index)"
                name = "\(baseName)\(suffix).\(ext)"
            } else {
                let suffix = index == 0 ? "" : " \(index)"
                name = "\(baseName)\(suffix)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    static func createNewItem(in directory: URL, extensionName: String?) throws -> URL {
        if let ext = extensionName {
            // Keep extension spelling/case exactly as configured (e.g. .R, .py).
            let url = uniqueURL(in: directory, baseName: "未命名", extensionName: ext)
            if let binary = defaultBinaryContents(for: ext) {
                try binary.write(to: url, options: .atomic)
            } else {
                let text = defaultTextContents(for: ext)
                if text.isEmpty {
                    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                } else {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            NSWorkspace.shared.noteFileSystemChanged(url.path)
            return url
        } else {
            let url = uniqueURL(in: directory, baseName: "未命名文件夹", extensionName: nil)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            NSWorkspace.shared.noteFileSystemChanged(url.path)
            return url
        }
    }

    static func defaultTextContents(for ext: String) -> String {
        switch ext.lowercased() {
        case "md": return "# 未命名\n\n"
        case "swift": return "import Foundation\n\n"
        case "py": return "#!/usr/bin/env python3\n\n"
        case "r": return "# 未命名\n\n"
        case "html": return "<!DOCTYPE html>\n<html>\n<head><meta charset=\"utf-8\"><title></title></head>\n<body>\n</body>\n</html>\n"
        case "json": return "{\n}\n"
        case "csv": return ""
        default: return ""
        }
    }

    /// Minimal valid OOXML stubs so Excel / Word / PowerPoint open cleanly.
    static func defaultBinaryContents(for ext: String) -> Data? {
        switch ext.lowercased() {
        case "xlsx":
            return OfficeDocumentStubs.xlsx
        case "docx":
            return OfficeDocumentStubs.docx
        case "pptx", "ppt":
            // "ppt" menu type creates a modern .pptx package (legacy binary .ppt is obsolete).
            return OfficeDocumentStubs.pptx
        default:
            return nil
        }
    }

    static func moveToTrash(_ urls: [URL]) throws {
        for url in urls {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        }
    }

    static func copyURLs(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString("", forType: pasteboardType)
    }

    static func cutURLs(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString("cut", forType: pasteboardType)
        if let data = try? JSONEncoder().encode(urls.map(\.path)) {
            pb.setData(data, forType: pasteboardType)
        }
    }

    static func isCutOnPasteboard() -> Bool {
        let pb = NSPasteboard.general
        return pb.string(forType: pasteboardType) == "cut" || pb.data(forType: pasteboardType) != nil
    }

    static func paste(into directory: URL) throws -> [URL] {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let cutting: Bool = {
            if let data = pb.data(forType: pasteboardType),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                return !paths.isEmpty
            }
            return pb.string(forType: pasteboardType) == "cut"
        }()

        var results: [URL] = []
        for source in urls {
            let dest = uniqueURL(
                in: directory,
                baseName: source.deletingPathExtension().lastPathComponent,
                extensionName: source.pathExtension.isEmpty ? nil : source.pathExtension
            )
            if cutting {
                try FileManager.default.moveItem(at: source, to: dest)
            } else {
                try FileManager.default.copyItem(at: source, to: dest)
            }
            results.append(dest)
        }

        if cutting {
            pb.clearContents()
        }
        return results
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    static func open(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                AppDelegate.shared.openURLs([url])
                continue
            }
            NSWorkspace.shared.open(url)
        }
    }

    static func revealInFinder(_ urls: [URL]) {
        AppDelegate.shared.reveal(urls)
    }

    static func formatFileSize(_ size: Int64?) -> String {
        guard let size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    static func pathAutocomplete(for input: String) -> [String] {
        let expanded = (input as NSString).expandingTildeInPath
        let url: URL
        let prefix: String
        if expanded.hasSuffix("/") {
            url = URL(fileURLWithPath: expanded, isDirectory: true)
            prefix = ""
        } else {
            url = URL(fileURLWithPath: expanded).deletingLastPathComponent()
            prefix = URL(fileURLWithPath: expanded).lastPathComponent
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(12)
            .map { candidate in
                var path = candidate.path
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    if !path.hasSuffix("/") { path += "/" }
                }
                return path
            }
    }

    static func search(in root: URL, query: String, limit: Int = 200) -> [URL] {
        let keywords = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return [] }

        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            let relative = fileURL.path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
            let haystack = relative.isEmpty ? name : relative
            if keywords.allSatisfy({ haystack.contains($0) }) {
                results.append(fileURL)
                if results.count >= limit { break }
            }
        }
        return results
    }

    static func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path != "/" }
    }
}
