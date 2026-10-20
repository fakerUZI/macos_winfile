import AppKit
import Darwin
import Foundation

// Independent Swift implementation. Rules identify disposable locations; no
// downloaded scripts, privileged operations, or permanent deletion are used.
enum StorageCleanupKind: String, CaseIterable, Identifiable, Codable {
    case cache, log, installer, largeFile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cache: return L("cleanup.cache", "应用缓存")
        case .log: return L("cleanup.log", "应用日志")
        case .installer: return L("cleanup.installer", "安装包")
        case .largeFile: return L("cleanup.large", "大文件")
        }
    }
}

struct StorageFileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
}
struct StorageFileSnapshot: Equatable {
    let identity: StorageFileIdentity
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        identity = StorageFileIdentity(value); size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}
struct StorageCleanupRule: Equatable {
    let root: URL
    let kind: StorageCleanupKind
    let owner: String
    let bundleID: String?
}
struct StorageCleanupFile: Identifiable {
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var modified: Date { Date(timeIntervalSince1970: TimeInterval(snapshot.modifiedSeconds)) }
    var size: Int64 { snapshot.size }
    let url: URL
    let rule: StorageCleanupRule
    let snapshot: StorageFileSnapshot
    let parentIdentity: StorageFileIdentity
    let rootIdentity: StorageFileIdentity
    let allocated: Int64
}
struct StorageCleanupConfiguration {
    var home: URL
    var largeFolder: URL?
    var ignored: [URL] = []
    var kinds = Set(StorageCleanupKind.allCases)
    /// nil scans all owners; an empty set deliberately scans none.
    var bundleIDs: Set<String>? = nil
    var minimumAgeDays = 7
    var minimumLargeBytes: Int64 = 100 * 1024 * 1024
    var entryLimit = 100_000
    var candidateLimit = 20_000
    var now = Date()
}
struct StorageFolderUsage: Identifiable {
    var id: String { url.path }
    let url: URL
    var bytes: Int64 = 0
    var files = 0
}
struct StorageCleanupProgress {
    var visited = 0
    var candidates = 0
    var bytes: Int64 = 0
    var currentPath = ""
}
struct StorageCleanupScanResult {
    var files: [StorageCleanupFile] = []
    var folders: [StorageFolderUsage] = []
    var inaccessible: [String] = []
    var skippedRunning = 0
    var skippedProtected = 0
    var visited = 0
    var scannedBytes: Int64 = 0
    var cancelled = false
    var limited = false

    mutating func removeTrashedFiles(_ ids: Set<String>) {
        let folderIndices = Dictionary(uniqueKeysWithValues: folders.indices.map { (folders[$0].url.standardizedFileURL.path, $0) })
        for file in files where ids.contains(file.id) {
            scannedBytes = max(0, scannedBytes - file.allocated)
            // A root bucket contains its direct files, while child buckets
            // contain their own subtrees. Charge only the most specific bucket.
            var parent = file.url.standardizedFileURL.deletingLastPathComponent()
            while true {
                if let index = folderIndices[parent.path] {
                    folders[index].bytes = max(0, folders[index].bytes - file.allocated)
                    folders[index].files = max(0, folders[index].files - 1)
                    break
                }
                let ancestor = parent.deletingLastPathComponent()
                guard ancestor != parent else { break }
                parent = ancestor
            }
        }
        files.removeAll { ids.contains($0.id) }
        folders.removeAll { $0.files == 0 }
        folders.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
}
struct StorageCleanupOutcome {
    var removed = Set<String>()
    var moves: [FileMoveRecord] = []
    var failures: [String] = []
    var bytes: Int64 = 0
    var cancelled = false
}

enum StorageCleanupService {
    static func contains(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path, boundary = root.standardizedFileURL.path
        return path == boundary || path.hasPrefix(boundary + "/")
    }
    private static func metadata(_ url: URL) -> stat? {
        var value = stat()
        return url.withUnsafeFileSystemRepresentation { p in
            guard let p, lstat(p, &value) == 0 else { return nil }
            return value
        }
    }
    private static func physical(_ url: URL) -> Bool {
        url.standardizedFileURL.path == url.resolvingSymlinksInPath().path
    }
    private static func protectedOwner(_ value: String) -> Bool {
        let name = value.lowercased()
        return name.hasPrefix("com.apple.") || ["spotify", "raycast", "mullvad", "orbstack", "1password",
            "bitwarden", "keepass", "keychain", "password", "tailscale", "wireguard", "clash", "cursor",
            "codex", "ollama", "com.openai", "com.anthropic", "com.todesktop.230313mzl4w4u"].contains { name.contains($0) }
    }
    private static func protectedFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        return ["db", "db3", "sqlite", "sqlite3", "realm", "mdb", "ldb", "keychain", "keychain-db", "pem", "key", "wallet"].contains(ext)
            || name.hasSuffix("-wal") || name.hasSuffix("-shm")
            || ["cookies", "login data", "history", "web data", "preferences", "local state"].contains(name)
            || name.contains("credential") || name.contains("password")
    }
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).map { $0.lowercased() })
    }
    static func isRunning(_ bundleID: String?, in running: Set<String>) -> Bool {
        guard let bundleID else { return false }
        let id = bundleID.lowercased()
        return running.contains { $0 == id || $0.hasPrefix(id + ".") || id.hasPrefix($0 + ".") }
    }
    static func allowedLargeFolder(_ root: URL, home: URL) -> Bool {
        let relative = root.pathComponents.dropFirst(home.pathComponents.count)
        return contains(root, in: home) && root != home && physical(root)
            && !relative.contains(where: { $0.hasPrefix(".") || $0 == "Library" || $0.hasSuffix(".app") })
    }
    static func rules(_ config: StorageCleanupConfiguration) -> [StorageCleanupRule] {
        let fm = FileManager.default
        let home = config.home.standardizedFileURL
        var result: [StorageCleanupRule] = []
        func add(_ path: String, _ kind: StorageCleanupKind, _ owner: String, _ id: String? = nil) {
            let root = home.appendingPathComponent(path)
            guard physical(root), let info = metadata(root), info.st_mode & S_IFMT == S_IFDIR,
                  !protectedOwner(id ?? owner) else { return }
            result.append(StorageCleanupRule(root: root, kind: kind, owner: id.flatMap { AppDataService.resolvedName(for: $0) } ?? owner, bundleID: id))
        }
        let caches = home.appendingPathComponent("Library/Caches")
        if physical(caches), let entries = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for entry in entries where AppDataService.looksLikeBundleID(entry.lastPathComponent) {
                add("Library/Caches/" + entry.lastPathComponent, .cache, entry.lastPathComponent, entry.lastPathComponent)
            }
        }
        // Explicit Electron/browser cache paths. Profiles, extensions, offline
        // databases and the rest of Application Support are never swept.
        let electron = [("Slack", "com.tinyspeck.slackmacgap"), ("discord", "com.hnc.Discord"),
                        ("Code", "com.microsoft.VSCode"), ("Microsoft Teams", "com.microsoft.teams2")]
        for (name, id) in electron {
            for leaf in ["Cache", "Code Cache", "GPUCache", "CachedData"] {
                add("Library/Application Support/\(name)/\(leaf)", .cache, name, id)
            }
        }
        for (name, id) in [("Google/Chrome", "com.google.Chrome"), ("Microsoft Edge", "com.microsoft.edgemac"),
                           ("BraveSoftware/Brave-Browser", "com.brave.Browser")] {
            let relative = "Library/Application Support/" + name
            let root = home.appendingPathComponent(relative)
            guard physical(root), let profiles = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
                for leaf in ["Cache", "Code Cache", "GPUCache"] {
                    add("\(relative)/\(profile)/\(leaf)", .cache, name, id)
                }
            }
        }
        let containers = home.appendingPathComponent("Library/Containers")
        if physical(containers), let entries = try? fm.contentsOfDirectory(atPath: containers.path) {
            for id in entries where AppDataService.looksLikeBundleID(id) {
                add("Library/Containers/\(id)/Data/Library/Caches", .cache, id, id)
            }
        }
        let logs = home.appendingPathComponent("Library/Logs")
        if physical(logs), let entries = try? fm.contentsOfDirectory(atPath: logs.path) {
            let known = ["Code": "com.microsoft.VSCode", "Slack": "com.tinyspeck.slackmacgap",
                         "discord": "com.hnc.Discord", "Google Chrome": "com.google.Chrome"]
            for name in entries {
                if let id = known[name] { add("Library/Logs/" + name, .log, name, id) }
                else if AppDataService.looksLikeBundleID(name) { add("Library/Logs/" + name, .log, name, name) }
            }
        }
        add("Downloads", .installer, L("place.downloads", "下载"))
        add("Desktop", .installer, L("place.desktop", "桌面"))
        let largeRoots = config.largeFolder.map { [$0] } ?? ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"].map { home.appendingPathComponent($0) }
        for root in largeRoots where allowedLargeFolder(root, home: home) {
            if let info = metadata(root), info.st_mode & S_IFMT == S_IFDIR {
                result.append(StorageCleanupRule(root: root, kind: .largeFile, owner: root.lastPathComponent, bundleID: nil))
            }
        }
        var seen = Set<String>()
        let bundleIDs = config.bundleIDs.map { Set($0.map { $0.lowercased() }) }
        return result.filter { rule in
            let matchesSoftware = bundleIDs.map { ids in rule.bundleID.map { ids.contains($0.lowercased()) } ?? false } ?? true
            return config.kinds.contains(rule.kind) && matchesSoftware
                && seen.insert(rule.kind.rawValue + ":" + rule.root.path).inserted
        }
    }
    private static func ignored(_ url: URL, config: StorageCleanupConfiguration) -> Bool {
        config.ignored.contains { contains(url, in: $0.standardizedFileURL) }
    }
    private static func eligible(_ url: URL, info: stat, rule: StorageCleanupRule, config: StorageCleanupConfiguration,
                                 cancelled: () -> Bool) -> Bool {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size > 0, info.st_blocks > 0, !protectedFile(url),
              !ignored(url, config: config), physical(url), contains(url, in: rule.root), url != rule.root,
              !((rule.kind == .largeFile || rule.kind == .installer) && url.lastPathComponent.hasPrefix(".")) else { return false }
        if rule.kind == .largeFile { return info.st_size >= max(1, config.minimumLargeBytes) }
        let cutoff = config.now.addingTimeInterval(-Double(max(0, config.minimumAgeDays)) * 86400)
        guard Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)) <= cutoff else { return false }
        if rule.kind == .installer {
            let ext = url.pathExtension.lowercased()
            if ["dmg", "pkg", "mpkg", "iso", "xip"].contains(ext) { return true }
            guard ext == "zip", let probe = probe("/usr/bin/unzip", ["-Z1", url.path], timeout: 2, cancelled: cancelled), probe.status == 0 else { return false }
            return String(decoding: probe.output, as: UTF8.self).split(separator: "\n").prefix(50).contains {
                $0.split(separator: "/").contains { ["app", "pkg", "dmg", "xip"].contains(URL(fileURLWithPath: String($0)).pathExtension.lowercased()) }
            }
        }
        return true
    }
    static func scan(_ config: StorageCleanupConfiguration, running: Set<String> = runningBundleIDs(),
                     cancelled: () -> Bool = { false }, progress: (StorageCleanupProgress) -> Void = { _ in }) -> StorageCleanupScanResult {
        var result = StorageCleanupScanResult()
        var state = StorageCleanupProgress()
        var seen = Set<String>()
        var candidatePaths = Set<String>()
        var measuredLarge = Set<String>()
        var usages: [String: StorageFolderUsage] = [:]
        let fm = FileManager.default
        for relative in ["Library/Caches", "Library/Logs", "Library/Containers", "Library/Application Support"] {
            let root = config.home.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: root.path), !FileManager.default.isReadableFile(atPath: root.path) {
                result.inaccessible.append(root.path)
            }
        }
        rootLoop: for rule in rules(config) {
            if cancelled() { result.cancelled = true; break }
            if ignored(rule.root, config: config) { continue }
            if isRunning(rule.bundleID, in: running) { result.skippedRunning += 1; continue }
            guard let rootInfo = metadata(rule.root), let walker = fm.enumerator(at: rule.root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants],
                errorHandler: { url, _ in result.inaccessible.append(url.path); return true }) else { continue }
            for case let rawURL as URL in walker {
                let url = rawURL.standardizedFileURL
                if cancelled() { result.cancelled = true; break rootLoop }
                if state.visited >= max(0, config.entryLimit) || result.files.count >= max(0, config.candidateLimit) {
                    result.limited = true; break rootLoop
                }
                state.visited += 1; state.currentPath = url.path
                if state.visited % 200 == 0 { progress(state) }
                guard let info = metadata(url) else { result.inaccessible.append(url.path); continue }
                if info.st_mode & S_IFMT == S_IFLNK || ignored(url, config: config) || !physical(url) {
                    // skipDescendants on a non-directory can suppress the next
                    // directory on macOS. Symbolic links are not traversed by
                    // this enumerator, so only prune actual directories.
                    if info.st_mode & S_IFMT == S_IFDIR { walker.skipDescendants() }
                    result.skippedProtected += 1; continue
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    if ["indexeddb", "local storage", "webstorage", "databases", "sessions", "backups", "offline", "service worker", "file", "files", "attach", "attachments", "download", "downloads", "messages", "chats", "xwechat_files"].contains(url.lastPathComponent.lowercased())
                        || [".git", ".ssh", ".gnupg", ".Trash", "Library"].contains(url.lastPathComponent)
                        || ((rule.kind == .largeFile || rule.kind == .installer) && url.lastPathComponent.hasPrefix(".")) { walker.skipDescendants() }
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFREG else { continue }
                let identity = "\(info.st_dev):\(info.st_ino)"
                // Installer and large-file scopes overlap. Measure once, but
                // allow the later rule to classify a file the first rule rejected.
                if seen.insert(identity).inserted {
                    let allocated = Int64(info.st_blocks) * 512
                    result.scannedBytes += allocated
                }
                if rule.kind == .largeFile && measuredLarge.insert(identity).inserted {
                        let allocated = Int64(info.st_blocks) * 512
                        let relative = url.pathComponents.dropFirst(rule.root.pathComponents.count)
                        let group = relative.count > 1 ? rule.root.appendingPathComponent(String(relative.first!)) : rule.root
                        var usage = usages[group.path] ?? StorageFolderUsage(url: group)
                        usage.bytes += allocated; usage.files += 1; usages[group.path] = usage
                }
                guard !candidatePaths.contains(url.path), eligible(url, info: info, rule: rule, config: config, cancelled: cancelled),
                      let parent = metadata(url.deletingLastPathComponent()) else { continue }
                candidatePaths.insert(url.path)
                result.files.append(StorageCleanupFile(url: url, rule: rule, snapshot: StorageFileSnapshot(info),
                    parentIdentity: StorageFileIdentity(parent), rootIdentity: StorageFileIdentity(rootInfo),
                    allocated: Int64(info.st_blocks) * 512))
                state.candidates = result.files.count; state.bytes += info.st_size
            }
        }
        if cancelled() { result.cancelled = true }
        result.visited = state.visited
        result.folders = usages.values.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        result.files.sort { $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size }
        result.inaccessible = Array(Set(result.inaccessible)).sorted()
        progress(state)
        return result
    }

    // Bounded read-only system probes. Output goes to private temporary files
    // to avoid pipe deadlock; timeout, cancellation and excessive output deny.
    static func probe(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                      cancelled: () -> Bool = { false }) -> (status: Int32, output: Data, errors: Data)? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("WinFile-Probe-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: directory) }
            let outputURL = directory.appendingPathComponent("out"), errorURL = directory.appendingPathComponent("err")
            guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  fm.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            let out = try FileHandle(forWritingTo: outputURL), err = try FileHandle(forWritingTo: errorURL)
            defer { try? out.close(); try? err.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                let size = ((try? fm.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.intValue ?? 0
                let errorSize = ((try? fm.attributesOfItem(atPath: errorURL.path)[.size]) as? NSNumber)?.intValue ?? 0
                if cancelled() || Date() >= deadline || size > 1024 * 1024 || errorSize > 1024 * 1024 {
                    process.terminate(); kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); return nil
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            let outputSize = (try fm.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? Int.max
            let errorSize = (try fm.attributesOfItem(atPath: errorURL.path)[.size] as? NSNumber)?.intValue ?? Int.max
            guard outputSize <= 1024 * 1024, errorSize <= 1024 * 1024 else { return nil }
            let data = try Data(contentsOf: outputURL), errors = try Data(contentsOf: errorURL)
            guard data.count <= 1024 * 1024, errors.count <= 1024 * 1024 else { return nil }
            return (process.terminationStatus, data, errors)
        } catch { return nil }
    }
    static func fileIsOpen(_ url: URL) -> Bool? {
        guard let result = probe("/usr/sbin/lsof", ["-nP", "-t", "--", url.path], timeout: 2) else { return nil }
        if result.status == 0 || !result.output.isEmpty { return true }
        return result.status == 1 && result.errors.isEmpty ? false : nil
    }
    static func trash(_ files: [StorageCleanupFile], config: StorageCleanupConfiguration,
                      running: () -> Set<String> = runningBundleIDs, isOpen: (URL) -> Bool? = fileIsOpen,
                      cancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in },
                      move: (URL) throws -> URL? = { url in
                          var destination: NSURL?
                          try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                          return destination as URL?
                      }) -> StorageCleanupOutcome {
        var outcome = StorageCleanupOutcome()
        let allowed = rules(config)
        var seen = Set<String>()
        for (index, file) in files.enumerated() where seen.insert(file.id).inserted {
            if cancelled() { outcome.cancelled = true; break }
            progress(index + 1)
            func unchanged() -> Bool {
                guard allowed.contains(file.rule), physical(file.rule.root), physical(file.url),
                      let info = metadata(file.url), let parent = metadata(file.url.deletingLastPathComponent()),
                      let root = metadata(file.rule.root), StorageFileSnapshot(info) == file.snapshot,
                      StorageFileIdentity(parent) == file.parentIdentity, StorageFileIdentity(root) == file.rootIdentity else { return false }
                return eligible(file.url, info: info, rule: file.rule, config: config, cancelled: cancelled)
            }
            guard unchanged() else { outcome.failures.append(L("cleanup.changed", "已变化、被忽略或不再符合规则：%@", file.url.path)); continue }
            guard !isRunning(file.rule.bundleID, in: running()) else {
                outcome.failures.append(L("cleanup.running", "应用正在运行，已跳过：%@", file.rule.owner)); continue
            }
            guard isOpen(file.url) == false else {
                outcome.failures.append(L("cleanup.open", "文件被占用或无法确认占用状态，已跳过：%@", file.url.path)); continue
            }
            if cancelled() { outcome.cancelled = true; break }
            guard unchanged(), !isRunning(file.rule.bundleID, in: running()) else {
                outcome.failures.append(L("cleanup.changed", "已变化、被忽略或不再符合规则：%@", file.url.path)); continue
            }
            do {
                let destination = try move(file.url)
                outcome.removed.insert(file.id); outcome.bytes += file.size
                if let destination, let record = FileMoveRecord(original: file.url, current: destination) { outcome.moves.append(record) }
            } catch { outcome.failures.append("\(file.url.path): \(error.localizedDescription)") }
        }
        return outcome
    }
}
