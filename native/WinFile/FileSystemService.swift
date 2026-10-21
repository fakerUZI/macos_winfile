// 纯函数式文件系统服务：不依赖主线程状态，可从后台任务安全调用
import AppKit
import Foundation

/// Shared by detached scans and their owning UI task.
final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

struct FileScanReport {
    var items: [FileItem] = []
    var limitReached = false
    var depthLimited = false
    var visitLimitReached = false
    var inaccessibleCount = 0
    var visited = 0
    var cancelled = false
    var isPartial: Bool { limitReached || depthLimited || visitLimitReached || inaccessibleCount > 0 || cancelled }
}

struct DirectorySizeResult {
    var bytes: Int64 = 0
    var files = 0
    var folders = 0
    var isComplete = true
    var inaccessibleCount = 0
}

/// 不含任何可变状态，全部方法都是 static，便于在后台线程执行 I/O
enum FileSystemService {

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isReadableKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .nameKey,
    ]

    // MARK: - 列目录

    static func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try directoryListing(directory, showHidden: showHidden).items
    }

    /// Return the actual browsing root with its entries so watchers and saved tabs use it too.
    static func directoryListing(_ requested: URL, showHidden: Bool) throws -> (directory: URL, items: [FileItem]) {
        let directory = requested.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            if (try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw FSError.unavailableSymlink(requested)
            }
            throw FSError.notFound(requested)
        }
        guard isDir.boolValue else { throw FSError.notDirectory(directory) }

        let raw = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        var items: [FileItem] = []
        items.reserveCapacity(raw.count)
        for url in raw {
            if let item = FileItem(url: url, resourceKeys: resourceKeys, showHidden: showHidden) {
                items.append(item)
            }
        }
        // Preserve ordinary URLs (including their directory hint) when the path did not change.
        return (directory.path == requested.path ? requested : directory,
                sort(items, field: .name, ascending: true))
    }

    static func listApplications() -> [FileItem] {
        let fm = FileManager.default
        // 本地使用形态：涵盖系统与用户级应用目录
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var apps: [FileItem] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in children where url.pathExtension.lowercased() == "app" {
                if let item = FileItem(url: url, resourceKeys: resourceKeys, showHidden: true) {
                    apps.append(item)
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return target == base || target.hasPrefix(base + "/")
    }

    // MARK: - 排序

    static func sort(_ items: [FileItem], field: SortField, ascending: Bool) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isContainer != rhs.isContainer { return lhs.isContainer }
            let result: ComparisonResult
            switch field {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .modified:
                result = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
            case .type:
                result = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
            case .size:
                let left = lhs.size ?? -1
                let right = rhs.size ?? -1
                result = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: - 目录统计

    static func directorySize(_ url: URL, limit: Int = 200_000,
                              cancelled: () -> Bool = { false }) -> DirectorySizeResult {
        var result = DirectorySizeResult()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in
                result.inaccessibleCount += 1; result.isComplete = false; return true
            }) else { result.isComplete = false; return result }
        var visited = 0
        for case let child as URL in enumerator {
            if cancelled() || visited >= limit { result.isComplete = false; break }
            visited += 1
            do {
                let values = try child.resourceValues(forKeys: keys)
                // Count logical file contents once per path; never follow aliases outside the folder.
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true { result.folders += 1 }
                else if values.isRegularFile == true {
                    result.files += 1
                    result.bytes += Int64(values.fileSize ?? 0)
                }
            } catch { result.inaccessibleCount += 1; result.isComplete = false }
        }
        return result
    }

    // MARK: - 有界、可取消且有完整性说明的扫描

    static func search(under root: URL, matching text: String, limit: Int = 400) -> [FileItem] {
        searchReport(under: root, matching: text, limit: limit).items
    }

    static func searchReport(under root: URL, matching text: String, limit: Int = 400,
                             entryLimit: Int = 100_000, showHidden: Bool = false,
                             criteria: FileSearchCriteria = FileSearchCriteria(),
                             recursive: Bool = true,
                             progress: (Int) -> Void = { _ in },
                             cancelled: () -> Bool = { false }) -> FileScanReport {
        guard (!text.isEmpty || criteria.isActive), criteria.isValid else { return FileScanReport() }
        var report = scanFiles(under: [root.standardizedFileURL.resolvingSymlinksInPath()], depth: recursive ? Int.max : 0, limit: limit, entryLimit: entryLimit,
                         showHidden: showHidden, cancelled: cancelled, progress: progress) {
            (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)) && criteria.matches($0)
        }
        // A deliberately shallow search has completed its requested scope.
        if !recursive { report.depthLimited = false }
        return report
    }

    static func categoryReport(_ category: FileCategory, under roots: [URL], depth: Int = 4,
                               budget: Int = 800, entryLimit: Int = 100_000,
                               cancelled: () -> Bool = { false }) -> FileScanReport {
        scanFiles(under: roots, depth: depth, limit: budget, entryLimit: entryLimit,
                  showHidden: false, cancelled: cancelled) { !$0.isDirectory && $0.category == category }
    }

    private static func scanFiles(under roots: [URL], depth: Int, limit: Int, entryLimit: Int,
                                  showHidden: Bool, cancelled: () -> Bool, progress: (Int) -> Void = { _ in },
                                  matching: (FileItem) -> Bool) -> FileScanReport {
        var result = FileScanReport()
        var seenDirectories = Set<String>()
        var seenFiles = Set<String>()
        var inaccessible = Set<String>()
        let fm = FileManager.default
        var lastProgress = Date.distantPast
        func stopped() -> Bool {
            if cancelled() { result.cancelled = true }
            return result.cancelled || result.limitReached || result.visitLimitReached
        }
        func walk(_ directory: URL, level: Int) {
            guard !stopped(), seenDirectories.insert(FileItem.canonicalID(for: directory)).inserted else { return }
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: resourceKeys + [.isPackageKey],
                    options: showHidden ? [] : [.skipsHiddenFiles])
            } catch { inaccessible.insert(directory.path); return }
            for url in children {
                if stopped() { return }
                guard result.visited < entryLimit else { result.visitLimitReached = true; return }
                result.visited += 1
                if result.visited % 256 == 0, Date().timeIntervalSince(lastProgress) >= 0.1 {
                    lastProgress = Date(); progress(result.visited)
                }
                guard let item = FileItem(url: url, resourceKeys: resourceKeys, showHidden: showHidden) else {
                    inaccessible.insert(url.path); continue
                }
                guard !item.isSymlink else { continue }
                if matching(item), seenFiles.insert(item.id).inserted {
                    if result.items.count >= limit { result.limitReached = true; return }
                    result.items.append(item)
                }
                if item.isDirectory && !item.isBundle {
                    let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
                    if isPackage { continue }
                    if level < depth { walk(url, level: level + 1) }
                    else { result.depthLimited = true }
                }
            }
        }
        for root in roots {
            if stopped() { break }
            let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { continue }
            walk(root, level: 0)
        }
        progress(result.visited)
        result.inaccessibleCount = inaccessible.count
        result.items = sort(result.items, field: .modified, ascending: false)
        return result
    }

    /// 按分类在给定范围内收集文件（分类视图的数据源）
    ///
    /// 采用**有界目录遍历**：深度与条目数都有上限，耗时可控、不依赖 Spotlight 索引，
    /// 因此在外置卷、未索引目录下行为一致。
    ///
    /// 说明：曾尝试用 NSMetadataQuery 走 Spotlight 索引，但它需要稳定的主运行循环，
    /// 且构造谓词时可能抛出异常（实测触发过 SIGABRT），索引缺失时结果也不完整；
    /// 为保证可预期与稳定，统一使用有界遍历。
    static func categoryFiles(
        _ category: FileCategory,
        under roots: [URL],
        depth: Int = 4,
        budget: Int = 800
    ) -> [FileItem] {
        categoryFilesByWalking(category, under: roots, depth: depth, budget: budget)
    }

    /// 分类检索的条目上限（徽标与列表共用，界面会提示截断）
    static let categoryBudget = 800

    // MARK: 遍历兜底

    static func categoryFilesByWalking(
        _ category: FileCategory,
        under roots: [URL],
        depth: Int = 4,
        budget: Int = 800
    ) -> [FileItem] {
        categoryReport(category, under: roots, depth: depth, budget: budget).items
    }

    /// 按文件路径去重，保持原有顺序
    static func deduplicateByPath(_ items: [FileItem]) -> [FileItem] {
        var seen = Set<String>()
        var result: [FileItem] = []
        result.reserveCapacity(items.count)
        for item in items where seen.insert(item.url.path).inserted {
            result.append(item)
        }
        return result
    }

    /// 分类计数（受搜索范围限制）
    /// 最近修改的文件（主页「最近使用」的数据源之一）
    /// 有界遍历：深度与条目数都受限，结果按修改时间倒序。
    static func recentFiles(
        under roots: [URL],
        depth: Int = 4,
        budget: Int = 400,
        perDirectoryLimit: Int = 2000
    ) -> [FileItem] {
        var collected: [FileItem] = []
        let fm = FileManager.default

        func walk(_ directory: URL, level: Int) {
            if collected.count >= budget || level > depth { return }
            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ), children.count <= perDirectoryLimit else { return }
            for url in children {
                if collected.count >= budget { return }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                if values.isDirectory == true {
                    if level < depth { walk(url, level: level + 1) }
                    continue
                }
                if let item = FileItem(url: url, resourceKeys: resourceKeys, showHidden: false) {
                    collected.append(item)
                }
            }
        }

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            walk(root, level: 0)
        }
        // 同样需要按路径去重：范围 ["<家目录>", "/"] 存在包含关系，
        // 否则最近使用列表里会出现重复条目
        let unique = deduplicateByPath(collected)
        let sorted = unique.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return Array(sorted.prefix(budget))
    }

    /// 分类计数：与 categoryFiles 使用**相同的深度与上限**，
    /// 保证侧边栏徽标数字与点进去看到的条目数完全一致。
    ///
    /// 与 categoryFiles 一样处理大目录；当所有可能出现的
    /// 分类都达到上限后提前结束遍历（结果不会再变化，没必要走完整个磁盘）。
    static func categoryCounts(under roots: [URL], depth: Int = 4, budget: Int = 800) -> [FileCategory: Int] {
        let report = scanFiles(under: roots, depth: depth, limit: Int.max, entryLimit: 100_000,
                               showHidden: false, cancelled: { false }) { !$0.isDirectory }
        var counts: [FileCategory: Int] = [:]
        for item in report.items { counts[item.category] = min(budget, (counts[item.category] ?? 0) + 1) }
        return counts
    }

    /// 沙盒会把「家目录」重定向到容器内（…/Library/Containers/<bundle-id>/Data），
    /// 这里解析出真实的家目录，便于在侧边栏展示用户真正的常用文件夹。
    static func realHomeDirectory() -> URL {
        let containerHome = FileManager.default.homeDirectoryForCurrentUser
        let path = containerHome.path
        if let range = path.range(of: "/Library/Containers/") {
            let realPath = String(path[path.startIndex..<range.lowerBound])
            if !realPath.isEmpty {
                return URL(fileURLWithPath: realPath)
            }
        }
        return containerHome
    }


    /// 把绝对路径缩写为 ~ 形式，便于界面展示
    static func abbreviate(_ url: URL) -> String {
        let home = realHomeDirectory().path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// 展开 ~ 并规范化路径
    static func resolve(path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
