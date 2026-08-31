import Foundation

enum UpdateChecker {
    static let repository = "yikeshu0611/FinderPathBar"

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
        let releaseNotes: String
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func fetchLatest(completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("NewFinder-UpdateChecker", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(CocoaError(.fileReadUnknown)))
                }
                return
            }
            do {
                let info = try parseReleaseJSON(data)
                DispatchQueue.main.async { completion(.success(info)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        compareVersions(candidate, installed) == .orderedDescending
    }

    static func download(_ release: ReleaseInfo, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("NewFinder-UpdateChecker", forHTTPHeaderField: "User-Agent")

        URLSession.shared.downloadTask(with: request) { tempURL, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let tempURL else {
                DispatchQueue.main.async { completion(.failure(CocoaError(.fileReadUnknown))) }
                return
            }
            let fileName = release.downloadURL.lastPathComponent.isEmpty
                ? "NewFinder-\(release.version).dmg"
                : release.downloadURL.lastPathComponent
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                DispatchQueue.main.async { completion(.success(dest)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private static func parseReleaseJSON(_ data: Data) throws -> ReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !tag.isEmpty else { throw CocoaError(.propertyListReadCorrupt) }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmgAsset = assets.first { item in
            (item["name"] as? String)?.lowercased().hasSuffix(".dmg") == true
        }
        guard let urlString = dmgAsset?["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let notes = json["body"] as? String ?? ""
        return ReleaseInfo(version: tag, downloadURL: downloadURL, releaseNotes: notes)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va < vb { return .orderedAscending }
            if va > vb { return .orderedDescending }
        }
        return .orderedSame
    }
}
