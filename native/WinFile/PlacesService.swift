// 主页（Home）与此电脑（This PC）的数据层
// - 主页：快速访问、收藏夹（可固定）、最近修改 + 最近打开
// - 此电脑：设备与驱动器（容量、可用空间、可弹出）
import AppKit
import Foundation

// MARK: - 驱动器

struct DriveInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let isRoot: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isInternal: Bool
    let totalBytes: Int64
    let freeBytes: Int64
    let fileSystem: String?
    let isReadOnly: Bool
    let isLocal: Bool

    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var usedText: String { FileItem.formatSize(usedBytes) }
    var freeText: String { FileItem.formatSize(freeBytes) }
    var totalText: String { FileItem.formatSize(totalBytes) }

    /// 进度条颜色：与 Windows 类似，空间紧张时变红
    var barColor: NSColor {
        if usedFraction >= 0.9 { return .systemRed }
        if usedFraction >= 0.75 { return .systemOrange }
        return .systemBlue
    }

    var symbol: String {
        if isRoot { return "internaldrive.fill" }
        if isRemovable { return "externaldrive.fill" }
        return "externaldrive.connected.to.line.below.fill"
    }

    var kindDescription: String {
        if isRoot { return L("drive.kind.system", "系统磁盘") }
        if isDiskImage { return L("drive.kind.diskImage", "磁盘映像（只读）") }
        if isRemovable { return L("drive.kind.removable", "可移动磁盘") }
        return L("drive.kind.external", "外置磁盘")
    }

    /// 已挂载的 .dmg / 只读映像：这类卷“可用空间为 0”是正常现象，不应显示成磁盘快满
    var isDiskImage: Bool {
        !isRoot && isReadOnly
    }

    /// 容量条是否可信（只读映像的可用空间没有参考价值）
    var showsCapacityBar: Bool { totalBytes > 0 && !isDiskImage }

    static func == (lhs: DriveInfo, rhs: DriveInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 最近使用条目

struct RecentEntry: Identifiable, Hashable {
    let item: FileItem
    /// 是否来自「应用内打开过」的记录
    let openedRecently: Bool
    let lastOpened: Date?
    let lastModified: Date?

    var id: String { item.id }

    /// 用于排序的时间：最近打开优先，其次修改时间
    var sortDate: Date {
        let opened = lastOpened ?? .distantPast
        let modified = lastModified ?? .distantPast
        return max(opened, modified)
    }

    /// 展示用的时间说明
    var timeDescription: String {
        if let opened = lastOpened, opened >= (lastModified ?? .distantPast) {
            return L("recent.opened", "打开于 %@", FileItem.formatDate(opened))
        }
        return L("recent.modified", "修改于 %@", FileItem.formatDate(lastModified ?? Date()))
    }

    static func == (lhs: RecentEntry, rhs: RecentEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 收藏夹 / 打开历史（持久化）

/// 用户固定的收藏夹与应用内「最近打开」记录
final class FavoritesStore {

    static let shared = FavoritesStore()

    private let favoritesKey = "PinnedFolders"
    private let openedKey = "RecentlyOpenedFiles"
    private let maxOpened = 60

    private var openedCache: [String: Date]

    private init() {
        openedCache = FavoritesStore.loadOpened(key: openedKey)
    }

    // MARK: 收藏夹

    /// 固定的文件夹（返回仍然存在的那些）
    var pinnedFolders: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedFolders.contains { $0.path == url.standardizedFileURL.path }
    }

    @discardableResult
    func pin(_ url: URL) -> Bool {
        var paths = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return false }
        paths.append(path)
        UserDefaults.standard.set(paths, forKey: favoritesKey)
        return true
    }

    func unpin(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        paths.removeAll { $0 == path }
        UserDefaults.standard.set(paths, forKey: favoritesKey)
    }

    func togglePin(_ url: URL) {
        if isPinned(url) { unpin(url) } else { pin(url) }
    }

    // MARK: 最近打开

    private static func loadOpened(key: String) -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func recordOpened(_ url: URL) {
        let path = url.standardizedFileURL.path
        openedCache[path] = Date()
        // 只保留最近 maxOpened 条
        if openedCache.count > maxOpened {
            let sorted = openedCache.sorted { $0.value > $1.value }.prefix(maxOpened)
            openedCache = [String: Date](uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }
        let raw = openedCache.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: openedKey)
    }

    func lastOpened(_ url: URL) -> Date? {
        openedCache[url.standardizedFileURL.path]
    }

    var openedPaths: [String] { Array(openedCache.keys) }

    func clearOpened() {
        openedCache = [:]
        UserDefaults.standard.removeObject(forKey: openedKey)
    }
}

// MARK: - 主页 / 此电脑 数据构建

enum PlacesService {

    /// 快速访问磁贴：标准用户文件夹 + 常用位置
    static func quickAccessFolders() -> [SidebarPlace] {
        let fm = FileManager.default
        let home = FileSystemService.realHomeDirectory()
        var result: [SidebarPlace] = []
        func add(_ key: String, _ fallback: String, _ name: String, _ symbol: String) {
            let url = home.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return }
            result.append(SidebarPlace(id: url.path, name: L(key, fallback), url: url,
                                       kind: .folder, symbol: symbol))
        }
        add("place.desktop", "桌面", "Desktop", "menubar.dock.rectangle")
        add("place.downloads", "下载", "Downloads", "arrow.down.circle")
        add("place.documents", "文稿", "Documents", "doc")
        add("place.pictures", "图片", "Pictures", "photo")
        add("place.movies", "影片", "Movies", "film")
        add("place.music", "音乐", "Music", "music.note")
        let applications = URL(fileURLWithPath: "/Applications")
        if fm.fileExists(atPath: applications.path) {
            result.append(SidebarPlace(id: applications.path,
                                       name: L("place.applications", "应用程序"),
                                       url: applications, kind: .applications, symbol: "square.grid.2x2"))
        }
        if !result.contains(where: { $0.url.path == home.path }) {
            result.append(SidebarPlace(id: home.path, name: L("place.home", "个人文件夹"),
                                       url: home, kind: .home, symbol: "house"))
        }
        return result
    }

    /// 最近使用：合并「最近打开」（应用内记录）与「最近修改」（文件系统时间）
    static func recentEntries(
        under roots: [URL],
        depth: Int = 4,
        budget: Int = 400,
        limit: Int = 30
    ) -> [RecentEntry] {
        let store = FavoritesStore.shared
        var entries: [RecentEntry] = []
        var seen = Set<String>()

        // 1) 应用内打开过的文件（优先展示）
        for path in store.openedPaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path),
                  let item = FileItem(url: url, resourceKeys: FileSystemService.resourceKeys, showHidden: true)
            else { continue }
            seen.insert(item.id)
            entries.append(RecentEntry(item: item, openedRecently: true,
                                       lastOpened: store.lastOpened(url),
                                       lastModified: item.modified))
        }

        // 2) 最近修改的文件（受范围与深度限制）
        let modified = FileSystemService.recentFiles(under: roots, depth: depth, budget: budget)
        for item in modified where !seen.contains(item.id) {
            entries.append(RecentEntry(item: item, openedRecently: false,
                                       lastOpened: nil, lastModified: item.modified))
        }

        entries.sort { $0.sortDate > $1.sortDate }
        return Array(entries.prefix(limit))
    }

    /// 枚举所有已挂载的驱动器（Windows「此电脑」的“设备和驱动器”）
    static func drives() -> [DriveInfo] {
        let fm = FileManager.default
        var candidates: [URL] = [URL(fileURLWithPath: "/")]
        let volumes = URL(fileURLWithPath: "/Volumes")
        if let children = try? fm.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                         .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsLocalKey,
                                         .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeURLForRemountingKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: children)
        }

        var result: [DriveInfo] = []
        var seenDevices = Set<UInt64>()   // 用设备号去重：/Volumes/X 可能是指向 / 的符号链接
        for url in candidates {
            let keys: Set<URLResourceKey> = [
                .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
                .volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }

            // 去重：同一个底层设备只展示一次（例如 /Volumes/Macintosh HD → /）
            var statInfo = stat()
            if stat(url.path, &statInfo) == 0 {
                let device = UInt64(bitPattern: Int64(statInfo.st_dev))
                if seenDevices.contains(device) { continue }
                seenDevices.insert(device)
            }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            let isRoot = url.path == "/"
            let name = isRoot
                ? L("place.macintoshHD", "Macintosh HD")
                : (values.volumeName ?? url.lastPathComponent)
            result.append(DriveInfo(
                id: url.path,
                name: name,
                url: url,
                isRoot: isRoot,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isInternal: values.volumeIsInternal ?? false,
                totalBytes: total,
                freeBytes: max(0, free),
                fileSystem: fileSystemType(of: url),
                isReadOnly: (values.volumeIsReadOnly ?? false) || isReadOnlyMount(url),
                isLocal: values.volumeIsLocal ?? true
            ))
        }
        // 启动磁盘排在最前
        return result.sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 该挂载点是否为只读（statfs 的 MNT_RDONLY 标志）
    private static func isReadOnlyMount(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        return (info.f_flags & UInt32(MNT_RDONLY)) != 0
    }

    private static func fileSystemType(of url: URL) -> String? {
        // 不调用外部命令（沙盒禁止）；用 statfs 读取文件系统类型
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let flags = Int32(info.f_flags)
        // MNT_RDONLY 等标志不在此处解释，只取类型名
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        _ = flags
        return type.isEmpty ? nil : type
    }

    /// 弹出（卸载）可移动磁盘
    @discardableResult
    static func eject(_ drive: DriveInfo) -> Bool {
        guard !drive.isRoot else { return false }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: drive.url)
            return true
        } catch {
            return false
        }
    }
}
