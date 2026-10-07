// 纯函数式文件系统服务：不依赖主线程状态，可从后台任务安全调用
import AppKit
import Foundation

/// 不含任何可变状态，全部方法都是 static，便于在后台线程执行 I/O
enum FileSystemService {

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isReadableKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .nameKey,
    ]

    // MARK: - 列目录

    static func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            throw FSError.notFound(directory)
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
        return sort(items, field: .name, ascending: true)
    }

    static func listApplications(allowedRoots: [URL]? = nil) -> [FileItem] {
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

    static func directorySize(_ url: URL, limit: Int = 200_000) -> (bytes: Int64, files: Int, folders: Int) {
        let fm = FileManager.default
        var bytes: Int64 = 0
        var files = 0
        var folders = 0
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return (0, 0, 0) }
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited > limit { break }
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { continue }
            if values.isDirectory == true {
                folders += 1
            } else {
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (bytes, files, folders)
    }

    // MARK: - 搜索

    static func search(under root: URL, matching text: String, limit: Int = 400) -> [FileItem] {
        let needle = text.lowercased()
        guard !needle.isEmpty else { return [] }
        let fm = FileManager.default
        var results: [FileItem] = []
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return [] }
        for case let url as URL in enumerator {
            if results.count >= limit { break }
            guard url.lastPathComponent.lowercased().contains(needle) else { continue }
            if let item = FileItem(url: url, resourceKeys: resourceKeys, showHidden: false) {
                results.append(item)
            }
        }
        return results
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
        var results: [FileItem] = []
        let fm = FileManager.default

        func walk(_ directory: URL, level: Int) {
            if results.count >= budget || level > depth { return }
            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ), children.count <= 3000 else { return }
            for url in children {
                if results.count >= budget { return }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                if values.isDirectory == true {
                    if level < depth { walk(url, level: level + 1) }
                    continue
                }
                let info = FileTypeDB.info(name: url.lastPathComponent, isDirectory: false,
                                           isSymlink: values.isSymbolicLink ?? false, isBundle: false)
                guard info.category == category else { continue }
                if let item = FileItem(url: url, resourceKeys: resourceKeys, showHidden: false) {
                    results.append(item)
                }
            }
        }

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            walk(root, level: 0)
            if results.count >= budget { break }
        }
        // 按路径去重。
        //
        // 必要性：可浏览范围是 ["/Users/mac", "/"]，前者包含在后者内，
        // 因此 / 的遍历会再次走到家目录下的文件。此前只拼接各范围结果而不查重，
        // 导致同一条目出现两次（用户实测：分类计数 16 但只有 14 个不同文件，
        // 图标视图只画出 14 个，且点一个会同时选中两个 —— 它们共享同一路径即同一 id）。
        let unique = deduplicateByPath(results)
        return sort(unique, field: .modified, ascending: false)
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
        // 同样需要按路径去重：范围 ["/Users/mac", "/"] 存在包含关系，
        // 否则最近使用列表里会出现重复条目
        let unique = deduplicateByPath(collected)
        let sorted = unique.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return Array(sorted.prefix(budget))
    }

    /// 分类计数：与 categoryFiles 使用**相同的深度与上限**，
    /// 保证侧边栏徽标数字与点进去看到的条目数完全一致。
    static func categoryCounts(under roots: [URL], depth: Int = 4, budget: Int = 800) -> [FileCategory: Int] {
        var counts: [FileCategory: Int] = [:]
        var counted = Set<String>()   // 已计入的文件路径，避免重复计数
        let fm = FileManager.default

        func walk(_ directory: URL, level: Int) {
            if level > depth { return }
            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return }
            for url in children {
                // 单个分类达到上限即封顶，与 categoryFiles 的截断行为保持一致
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                if values.isDirectory == true {
                    walk(url, level: level + 1)
                    continue
                }
                guard let item = FileItem(url: url, resourceKeys: resourceKeys, showHidden: false) else { continue }
                // 按路径去重后再计数：范围存在包含关系（/Users/mac ⊂ /），
                // 否则同一个文件会被计两次，徽标数字虚高
                guard counted.insert(item.url.path).inserted else { continue }
                let info = FileTypeDB.info(name: item.name, isDirectory: false,
                                           isSymlink: values.isSymbolicLink ?? false, isBundle: false)
                let next = (counts[info.category] ?? 0) + 1
                counts[info.category] = min(next, budget)
            }
        }

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            walk(root, level: 0)
        }
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
