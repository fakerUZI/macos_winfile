// 原生文件系统引擎：目录列表、分类聚合、搜索、废纸篓、书签授权
import AppKit
import Foundation
import Combine
import Security

// MARK: - 侧边栏位置

struct SidebarPlace: Identifiable, Hashable {
    enum Kind: String { case folder, volume, applications, home, user }
    let id: String
    let name: String
    let url: URL
    let kind: Kind
    let symbol: String

    static func == (lhs: SidebarPlace, rhs: SidebarPlace) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 引擎

@MainActor
final class FSEngine: ObservableObject {

    // 资源键一次取齐，避免逐项系统调用
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isReadableKey,
        .fileSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .creationDateKey, .nameKey,
    ]

    @Published private(set) var places: [SidebarPlace] = []
    @Published private(set) var volumes: [SidebarPlace] = []
    @Published private(set) var authorizedRoots: [URL] = []
    @Published private(set) var categoryCounts: [FileCategory: Int] = [:]
    @Published private(set) var countingCategories = false
    @Published var lastError: String?

    /// 已添加根路径快照：由主线程在变化时更新，nonisolated 代码只读
    private nonisolated(unsafe) static var allowedPathsSnapshot: [String] = []
    /// 用户添加的常用文件夹（本地版直接记录路径，无需沙盒书签）
    private var addedFolderPaths: [String] = []
    private var countTask: Task<Void, Never>?
    private var languageSubscription: AnyCancellable?

    private let foldersKey = "AddedFolderPaths"

    init() {
        loadAddedFolders()
        seedFavoritesIfNeeded()
        buildPlaces()
        buildVolumes()
        refreshAuthorizedRoots()
        languageSubscription = Localization.shared.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.buildPlaces()
                self?.buildVolumes()
            }
    }


    // MARK: - 位置

    private func buildPlaces() {
        let fm = FileManager.default
        // 沙盒下 homeDirectoryForCurrentUser 指向容器，侧边栏要展示用户真实的家目录
        let home = FileSystemService.realHomeDirectory()
        var list: [SidebarPlace] = []
        func add(_ titleKey: String, _ url: URL, _ symbol: String, _ kind: SidebarPlace.Kind) {
            guard fm.fileExists(atPath: url.path) else { return }
            list.append(SidebarPlace(id: url.path, name: WLocalizedString(titleKey, comment: "侧边栏位置"),
                                     url: url, kind: kind, symbol: symbol))
        }
        add("place.desktop", home.appendingPathComponent("Desktop"), "menubar.dock.rectangle", .folder)
        add("place.downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle", .folder)
        add("place.documents", home.appendingPathComponent("Documents"), "doc", .folder)
        add("place.pictures", home.appendingPathComponent("Pictures"), "photo", .folder)
        add("place.movies", home.appendingPathComponent("Movies"), "film", .folder)
        add("place.music", home.appendingPathComponent("Music"), "music.note", .folder)
        add("place.home", home, "house", .home)
        add("place.applications", URL(fileURLWithPath: "/Applications"), "square.grid.2x2", .applications)
        add("place.shared", URL(fileURLWithPath: "/Users/Shared"), "person.2", .folder)
        places = list
    }

    private func buildVolumes() {
        var list: [SidebarPlace] = []
        let root = URL(fileURLWithPath: "/")
        list.append(SidebarPlace(id: "/", name: WLocalizedString("place.macintoshHD", comment: "启动磁盘"),
                                 url: root, kind: .volume, symbol: "internaldrive"))
        let volumesRoot = URL(fileURLWithPath: "/Volumes")
        if let children = try? FileManager.default.contentsOfDirectory(
            at: volumesRoot, includingPropertiesForKeys: [.isVolumeKey], options: [.skipsHiddenFiles]
        ) {
            for child in children {
                list.append(SidebarPlace(id: child.path, name: child.lastPathComponent,
                                         url: child, kind: .volume, symbol: "externaldrive"))
            }
        }
        volumes = list
    }

    // MARK: - 常用文件夹

    private func loadAddedFolders() {
        addedFolderPaths = (UserDefaults.standard.array(forKey: foldersKey) as? [String]) ?? []
    }

    private func saveAddedFolders() {
        UserDefaults.standard.set(addedFolderPaths, forKey: foldersKey)
    }

    private func refreshAuthorizedRoots() {
        // 只保留仍然存在的目录
        let alive = addedFolderPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if alive.count != addedFolderPaths.count {
            addedFolderPaths = alive
            saveAddedFolders()
        }
        authorizedRoots = alive.map { URL(fileURLWithPath: $0) }
        refreshAllowedSnapshot()
    }

    /// 添加一个常用文件夹（本地版直接访问，无需授权）
    @discardableResult
    func addFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !addedFolderPaths.contains(path) else { return false }
        addedFolderPaths.append(path)
        saveAddedFolders()
        refreshAuthorizedRoots()
        scheduleCategoryCount()
        return true
    }

    /// 首次启动时为收藏列表填入标准文件夹。
    ///
    /// 说明：此前侧边栏「个人收藏」固定显示桌面/下载/文稿等标准位置，
    /// 与可增删的「常用文件夹」重复。现统一为一套可管理的收藏列表，
    /// 首次运行用标准位置作为初始值，用户随后可自由增删排序。
    private func seedFavoritesIfNeeded() {
        let seededKey = "FavoritesSeeded"
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        guard addedFolderPaths.isEmpty else { return }
        let home = FileSystemService.realHomeDirectory()
        let standard = ["Desktop", "Downloads", "Documents", "Pictures", "Movies", "Music"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        addedFolderPaths = standard.map { $0.standardizedFileURL.path }
        saveAddedFolders()
    }

    /// 重新填入标准收藏文件夹（管理面板的「恢复默认」使用）
    func seedStandardFavorites() {
        let home = FileSystemService.realHomeDirectory()
        let standard = ["Desktop", "Downloads", "Documents", "Pictures", "Movies", "Music"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.standardizedFileURL.path }
        addedFolderPaths = standard
        saveAddedFolders()
        refreshAuthorizedRoots()
        scheduleCategoryCount()
    }

    /// 移动收藏项（右键「上移/下移」与拖拽排序）
    func moveFolder(_ url: URL, by offset: Int) {
        let path = url.standardizedFileURL.path
        guard let index = addedFolderPaths.firstIndex(of: path) else { return }
        let target = index + offset
        guard addedFolderPaths.indices.contains(target) else { return }
        addedFolderPaths.swapAt(index, target)
        saveAddedFolders()
        refreshAuthorizedRoots()
    }

    /// 是否可移动
    func canMoveFolder(_ url: URL, by offset: Int) -> Bool {
        let path = url.standardizedFileURL.path
        guard let index = addedFolderPaths.firstIndex(of: path) else { return false }
        return addedFolderPaths.indices.contains(index + offset)
    }

    /// 从常用列表移除单个文件夹
    func removeFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        addedFolderPaths.removeAll { $0 == path }
        saveAddedFolders()
        refreshAuthorizedRoots()
    }

    func removeAllAddedFolders() {
        addedFolderPaths = []
        saveAddedFolders()
        authorizedRoots = []
        refreshAllowedSnapshot()
        categoryCounts = [:]
    }


    /// 可浏览的根：
    /// - 有授权：只能用授权目录（沙盒规范）
    /// - 沙盒首次启动：回落到应用容器目录与「应用程序」，避免打开即空白无从下手
    /// - 本地模式：整个磁盘
    /// - 测试/快照可显式覆盖（见 scopeOverrideForTesting）
    /// 可浏览范围：本地使用形态 = 整个磁盘。
    /// 用户添加的常用文件夹只是快捷入口，不限制可访问范围。
    var browsableRoots: [URL] {
        if let override = scopeOverrideForTesting { return override }
        return [FileSystemService.realHomeDirectory(), URL(fileURLWithPath: "/")]
    }

    /// 仅供测试/快照：显式覆盖可浏览范围，使分类检索范围可控
    var scopeOverrideForTesting: [URL]?

    /// 仅供测试：把授权范围限定为指定目录
    func restrictScopeForTesting(_ urls: [URL]) {
        scopeOverrideForTesting = urls
        authorizedRoots = urls
        refreshAllowedSnapshot()
    }

    /// 标准常用文件夹
    nonisolated var standardFolders: [URL] {
        let home = FileSystemService.realHomeDirectory()
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 本地使用形态下始终放行（保留方法以便上层调用无需分支）
    nonisolated func isAllowed(_ url: URL) -> Bool { true }

    /// 授权集合变化后刷新快照（主线程调用）
    private func refreshAllowedSnapshot() {
        FSEngine.allowedPathsSnapshot = authorizedRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

    // MARK: - 目录列表

    /// 列出已安装应用
    func listApplications() -> [FileItem] {
        FileSystemService.listApplications()
    }

    /// 启动应用或打开文件（沙盒允许，且是苹果推荐方式）
    @discardableResult
    func open(_ item: FileItem, withApplication bundleID: String? = nil) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let handler: (NSRunningApplication?, Error?) -> Void = { [weak self] _, error in
            if let error { Task { @MainActor in self?.lastError = error.localizedDescription } }
        }
        if let bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([item.url], withApplicationAt: appURL, configuration: config, completionHandler: handler)
            return true
        }
        let result = NSWorkspace.shared.open(item.url)
        if !result { lastError = WLocalizedString("error.openFailed", comment: "无法打开") }
        return result
    }

    func revealInFinder(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    /// 可打开该文件的应用（原生 Launch Services，取代原 Python 侧工具）
    func applications(for item: FileItem) -> [URL] {
        var result: [URL] = []
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: item.url) {
            result.append(handler)
        }
        for url in NSWorkspace.shared.urlsForApplications(toOpen: item.url) where !result.contains(url) {
            result.append(url)
        }
        return result
    }

    func defaultApplicationName(for item: FileItem) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: item.url) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    // MARK: - 分类聚合

    func scheduleCategoryCount(force: Bool = false) {
        guard force || categoryCounts.isEmpty else { return }
        countTask?.cancel()
        countingCategories = true
        let roots = browsableRoots
        countTask = Task { [weak self] in
            let counts = await Task.detached(priority: .utility) {
                FileSystemService.categoryCounts(under: roots)
            }.value
            guard !Task.isCancelled else { return }
            self?.categoryCounts = counts
            self?.countingCategories = false
        }
    }

    // MARK: - 文件操作（全部原生 API）

    nonisolated static func createFolder(in directory: URL, named name: String) throws -> URL {
        let target = uniqueURL(in: directory, name: name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    nonisolated static func createTextFile(in directory: URL, named name: String, contents: String = "") throws -> URL {
        let target = uniqueURL(in: directory, name: name, isDirectory: false)
        try contents.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    nonisolated static func rename(_ item: FileItem, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // "/" 与 ":" 在 macOS 文件名中非法（POSIX 层允许 ":"，但访达会显示成 "/"，
        // 跨应用复制时还会出问题，因此一并拒绝）
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else { throw FSError.invalidName }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard target.path != item.url.path else { return item.url }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FSError.nameExists(trimmed) }
        try FileManager.default.moveItem(at: item.url, to: target)
        return target
    }

    /// 移到废纸篓（原生 API，沙盒允许）
    nonisolated static func moveToTrash(_ items: [FileItem]) throws {
        for item in items {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
        }
    }

    nonisolated static func duplicate(_ items: [FileItem]) throws -> [URL] {
        var created: [URL] = []
        for item in items {
            let directory = item.url.deletingLastPathComponent()
            let base = item.url.deletingPathExtension().lastPathComponent
            let ext = item.url.pathExtension
            var candidate = directory.appendingPathComponent(
                ext.isEmpty ? "\(base) 副本" : "\(base) 副本.\(ext)"
            )
            var index = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent(
                    ext.isEmpty ? "\(base) 副本 \(index)" : "\(base) 副本 \(index).\(ext)"
                )
                index += 1
            }
            try FileManager.default.copyItem(at: item.url, to: candidate)
            created.append(candidate)
        }
        return created
    }

    enum TransferMode: Sendable { case copy, move }

    /// 复制/移动到目标目录；拒绝把文件夹放进它自己或子目录
    nonisolated static func transfer(_ items: [FileItem], to directory: URL, mode: TransferMode) throws -> [URL] {
        var created: [URL] = []
        let destPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        for item in items {
            if item.isDirectory {
                let sourcePath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
                if destPath == sourcePath || destPath.hasPrefix(sourcePath + "/") {
                    throw FSError.recursiveTransfer(item.name)
                }
            }
            if mode == .move, item.url.deletingLastPathComponent().path == directory.path { continue }
            let target = uniqueURL(in: directory, name: item.name, isDirectory: item.isDirectory)
            switch mode {
            case .copy: try FileManager.default.copyItem(at: item.url, to: target)
            case .move: try FileManager.default.moveItem(at: item.url, to: target)
            }
            created.append(target)
        }
        return created
    }

    /// 生成不冲突的目标文件名（"名称 2.ext"）
    nonisolated static func uniqueURL(in directory: URL, name: String, isDirectory: Bool) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = isDirectory ? "" : (candidate.pathExtension.isEmpty ? "" : "." + candidate.pathExtension)
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count))
        var index = 2
        repeat {
            candidate = directory.appendingPathComponent("\(stem) \(index)\(ext)")
            index += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

}

// MARK: - 错误

enum FSError: LocalizedError {
    case notFound(URL)
    case notDirectory(URL)
    case notAuthorized(URL)
    case invalidName
    case nameExists(String)
    case recursiveTransfer(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let url):
            return String(format: WLocalizedString("error.notFound", comment: "路径不存在"), url.lastPathComponent)
        case .notDirectory(let url):
            return String(format: WLocalizedString("error.notDirectory", comment: "不是文件夹"), url.lastPathComponent)
        case .notAuthorized:
            return WLocalizedString("error.notAccessible", comment: "无法访问该位置")
        case .invalidName:
            return WLocalizedString("error.invalidName", comment: "名称不合法")
        case .nameExists(let name):
            return String(format: WLocalizedString("error.nameExists", comment: "同名已存在"), name)
        case .recursiveTransfer(let name):
            return String(format: WLocalizedString("error.recursiveTransfer", comment: "不能放入自身"), name)
        }
    }
}
