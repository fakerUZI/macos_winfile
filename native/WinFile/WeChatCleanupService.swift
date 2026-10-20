import Foundation

/// Only ordinary attachment files are eligible; databases and symlinks are never offered.
enum WeChatFileKind: String, CaseIterable, Identifiable {
    case document, image, video, audio, archive, other
    var id: String { rawValue }
    var title: String { L("wechat.kind.\(rawValue)", rawValue) }
}

struct WeChatFile: Identifiable, Hashable {
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var typeDescription: String { kind.title }
    var parentPath: String { url.deletingLastPathComponent().path }
    let url: URL
    let root: URL
    let kind: WeChatFileKind
    let size: Int64
    let modified: Date
    let created: Date?
    let isReadable: Bool
    let accountID: String
    let month: String
    let isCache: Bool

    init(url: URL, root: URL, kind: WeChatFileKind, size: Int64, modified: Date,
         created: Date? = nil, isReadable: Bool = true) {
        self.url = url; self.root = root; self.kind = kind; self.size = size
        self.modified = modified; self.created = created; self.isReadable = isReadable
        let parts = Array(url.pathComponents.dropLast())
        if let account = parts.first(where: { $0.hasPrefix("wxid_") }) { accountID = account }
        else if let index = parts.firstIndex(of: "WeChat Files"), parts.indices.contains(index + 1) { accountID = parts[index + 1] }
        else { accountID = "custom" }
        if let stored = parts.last(where: { $0.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil }) { month = stored }
        else {
            let date = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: modified)
            month = String(format: "%04d-%02d", date.year ?? 0, date.month ?? 0)
        }
        let names: Set<String> = ["cache", "caches", "thumb", "thumbs", "thumbnail", "thumbnails", "temp", "tmp"]
        // A relocated WeChat folder may itself live inside the system Caches folder.
        // Classify only within the scanned root, including its own folder name.
        let rootParts = root.standardizedFileURL.pathComponents
        let fileParts = Array(url.standardizedFileURL.pathComponents.dropLast())
        let scopedParts = fileParts.starts(with: rootParts)
            ? Array(fileParts.dropFirst(max(0, rootParts.count - 1)))
            : [url.deletingLastPathComponent().lastPathComponent]
        isCache = scopedParts.contains { names.contains($0.lowercased()) }
    }
}

struct WeChatScanProgress {
    var files = 0
    var bytes: Int64 = 0
    var visited = 0
    var currentPath = ""
}

struct WeChatScanResult {
    var files: [WeChatFile] = []
    var roots: [URL] = []
    var inaccessible: [String] = []
}

struct WeChatTrashResult {
    var removed: Set<String> = []
    var failures: [String] = []
}

enum WeChatCleanupService {
    static let customRootsPreferenceKey = "WeChatCleanupFolders"
    static func excludesDirectory(_ name: String) -> Bool { excludedDirectories.contains(name.lowercased()) }
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .creationDateKey, .isReadableKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey
    ]
    private static let excludedDirectories: Set<String> = [
        "db", "database", "databases", "db_storage", "config", "logs", "log", "preferences"
    ]
    private static let excludedExtensions: Set<String> = [
        "db", "sqlite", "sqlite3", "db-wal", "db-shm", "sqlite-wal", "sqlite-shm",
        "key", "pem", "plist"
    ]

    /// Covers legacy containers and newer xwechat_files layouts. User-selected folders
    /// cover relocated data. No chat database is opened or parsed.
    static func discoverRoots(home: URL) -> (roots: [URL], inaccessible: [String]) {
        let fm = FileManager.default
        var candidates = [
            "Library/Containers/com.tencent.xinWeChat/Data",
            "Library/Containers/com.tencent.WeChat/Data",
            "Library/Application Support/com.tencent.xinWeChat",
            "Library/Application Support/WeChat",
            "Library/Application Support/WeChatApp",
            "Documents/xwechat_files", "Documents/WeChat Files", "Documents/WeChat"
        ].map { home.appendingPathComponent($0) }
        var inaccessible: [String] = []
        for relative in ["Library/Containers", "Library/Group Containers"] {
            let parent = home.appendingPathComponent(relative)
            do {
                let entries = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])
                for entry in entries {
                    let name = entry.lastPathComponent.lowercased()
                    if name.contains("wechat") || name.contains("xinwechat") {
                        candidates.append(relative.hasSuffix("/Containers") ? entry.appendingPathComponent("Data") : entry)
                    } else if relative.hasSuffix("/Containers"), AppDataService.isUUID(entry.lastPathComponent) {
                        let metadata = entry.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                        if let data = try? Data(contentsOf: metadata),
                           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                           let identifier = dict["MCMMetadataIdentifier"] as? String,
                           ["com.tencent.xinWeChat", "com.tencent.WeChat"].contains(identifier) {
                            candidates.append(entry.appendingPathComponent("Data"))
                        }
                    }
                }
            } catch {
                if !isMissing(error) { inaccessible.append(parent.path) }
            }
        }
        let existing = candidates.filter { url in
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            } catch {
                if !isMissing(error) { inaccessible.append(url.path) }
                return false
            }
        }
        return (uniqueRoots(existing), Array(Set(inaccessible)).sorted())
    }

    static func uniqueRoots(_ urls: [URL]) -> [URL] {
        let sorted = Set(urls.map { $0.standardizedFileURL }).sorted { $0.path.count < $1.path.count }
        var roots: [URL] = []
        for url in sorted where !roots.contains(where: { contains(url, in: $0) }) { roots.append(url) }
        return roots
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    static func attachmentKind(url: URL, root: URL, explicitFolder: Bool = false) -> WeChatFileKind? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        guard !excludedExtensions.contains(ext), !name.hasSuffix("-wal"), !name.hasSuffix("-shm") else { return nil }
        guard contains(url, in: root) else { return nil }
        let relative = String(url.deletingLastPathComponent().path.dropFirst(root.path.count))
        let components = ([root.lastPathComponent] + relative.split(separator: "/").map(String.init)).map { $0.lowercased() }
        guard !components.contains(where: { excludedDirectories.contains($0) }) else { return nil }
        let folders = Set(components)
        let fileFolders: Set<String> = ["file", "files", "attach", "attachment", "attachments", "download", "downloads"]
        let images: Set<String> = ["image", "images", "img", "image2"]
        let videos: Set<String> = ["video", "videos"]
        let audios: Set<String> = ["audio", "voice", "voices", "voip"]
        guard explicitFolder || !folders.isDisjoint(with: fileFolders.union(images).union(videos).union(audios)) else { return nil }
        let category = FileTypeDB.info(name: url.lastPathComponent, isDirectory: false, isSymlink: false, isBundle: false).category
        switch category {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .archive: return .archive
        case .document, .spreadsheet, .presentation, .pdf, .ebook: return .document
        default:
            if !folders.isDisjoint(with: images) { return .image }
            if !folders.isDisjoint(with: videos) { return .video }
            if !folders.isDisjoint(with: audios) { return .audio }
            return .other
        }
    }

    static func scan(roots: [URL], explicitRoots: [URL] = [], cancelled: () -> Bool = { false },
                     onProgress: (WeChatScanProgress) -> Void = { _ in }) -> WeChatScanResult {
        var result = WeChatScanResult()
        var progress = WeChatScanProgress()
        let fm = FileManager.default
        let explicit = explicitRoots.map { $0.standardizedFileURL }
        for root in uniqueRoots(roots + explicitRoots) {
            if cancelled() { break }
            progress.currentPath = root.path
            onProgress(progress)
            // A relocated root containing a symlink is rejected as well as symlink entries.
            guard root.resolvingSymlinksInPath().path == root.path else {
                result.inaccessible.append(root.path)
                continue
            }
            do {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                _ = try fm.contentsOfDirectory(atPath: root.path)
            } catch {
                result.inaccessible.append(root.path)
                continue
            }
            result.roots.append(root)
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) { url, _ in
                result.inaccessible.append(url.path)
                return true
            }
            guard let enumerator else { result.inaccessible.append(root.path); continue }
            for case let entry as URL in enumerator {
                if cancelled() { break }
                // Foundation enumerators may return /private/var while a root uses /var.
                // Normalize aliases without following attachment symlinks.
                let url = entry.standardizedFileURL
                progress.visited += 1
                progress.currentPath = url.deletingLastPathComponent().path
                if progress.visited % 256 == 0 { onProgress(progress) }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    // URL directory enumeration does not follow symlinks. Calling
                    // skipDescendants() on a non-directory link can skip sibling trees
                    // (e.g. Documents after a container's Music shortcut).
                    if values.isSymbolicLink == true { continue }
                    if values.isDirectory == true {
                        if excludedDirectories.contains(url.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                        continue
                    }
                    let explicitlySelected = explicit.contains { contains(url, in: $0) }
                    guard values.isRegularFile == true,
                          let kind = attachmentKind(url: url, root: root, explicitFolder: explicitlySelected),
                          let size = values.fileSize, let date = values.contentModificationDate else { continue }
                    result.files.append(WeChatFile(url: url, root: root, kind: kind, size: Int64(size), modified: date,
                                                       created: values.creationDate, isReadable: values.isReadable ?? false))
                    progress.files += 1
                    progress.bytes += Int64(size)
                } catch { result.inaccessible.append(url.path) }
            }
        }
        onProgress(progress)
        result.files.sort { $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size }
        result.inaccessible = Array(Set(result.inaccessible)).sorted()
        return result
    }

    /// Revalidate immediately before trashing; stale, changed or redirected files are retained.
    static func isUnchanged(_ file: WeChatFile) -> Bool {
        var freshURL = file.url
        freshURL.removeAllCachedResourceValues()
        guard contains(file.url, in: file.root), file.url.path != file.root.path,
              file.url.resolvingSymlinksInPath().path == file.url.path,
              let values = try? freshURL.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == file.size,
              values.contentModificationDate == file.modified,
              attachmentKind(url: file.url, root: file.root, explicitFolder: true) != nil else { return false }
        return true
    }

    static func trash(_ files: [WeChatFile], moveToTrash: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) -> WeChatTrashResult {
        var result = WeChatTrashResult()
        for file in files {
            guard isUnchanged(file) else {
                result.failures.append(L("wechat.changed", "文件已变化或不可访问，已跳过：%@", file.url.path))
                continue
            }
            do {
                try moveToTrash(file.url)
                result.removed.insert(file.id)
            } catch { result.failures.append("\(file.url.path): \(error.localizedDescription)") }
        }
        return result
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }
}
