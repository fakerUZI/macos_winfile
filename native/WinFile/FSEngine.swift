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
    var isEjectable = false

    static func == (lhs: SidebarPlace, rhs: SidebarPlace) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 引擎

struct SidebarFolderAddition {
    var added: [URL] = []
    var duplicateCount = 0
    var rejectedCount = 0

    var statusMessage: String {
        if duplicateCount == 0 && rejectedCount == 0 {
            return L("sidebar.add.success", "已将 %d 个文件夹添加到侧边栏", added.count)
        }
        if added.isEmpty && rejectedCount == 0 {
            return L("sidebar.add.duplicates", "%d 个文件夹已在侧边栏", duplicateCount)
        }
        return L("sidebar.add.result", "已添加 %d 个文件夹；%d 个已在侧边栏；%d 项无法添加（仅支持可读取的本地文件夹）",
                 added.count, duplicateCount, rejectedCount)
    }
}

struct CategoryScanRule: Codable, Hashable {
    var usesCustomRoots = false
    var paths: [String] = []
    var resultLimit = 800
}

struct CategoryScanConfiguration: Codable, Equatable {
    var usesCustomRoots = false
    var paths: [String] = []
    /// Zero means no result limit. Older saved configurations have no overrides.
    var resultLimit = 800
    var overrides: [String: CategoryScanRule]?

    var defaultRule: CategoryScanRule { CategoryScanRule(usesCustomRoots: usesCustomRoots, paths: paths, resultLimit: resultLimit) }
    func rule(for category: FileCategory?) -> CategoryScanRule {
        guard let category else { return defaultRule }
        return overrides?[category.rawValue] ?? defaultRule
    }
}

struct CategoryScanFolderAddition {
    var added = 0
    var duplicates = 0
    var rejected = 0

    var message: String? {
        if rejected > 0 {
            return L("category.settings.addResult", "已添加 %d 个目录，%d 个已存在，%d 个无法添加。", added, duplicates, rejected)
        }
        if added == 0 && duplicates > 0 { return L("category.settings.duplicates", "所选目录已在扫描范围中。") }
        return nil
    }
}

@MainActor
final class CategoryScanPreferences: ObservableObject {
    static let key = "CategoryScan.Configuration.v1"
    private let defaults: UserDefaults
    @Published private(set) var configuration: CategoryScanConfiguration

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(CategoryScanConfiguration.self, from: data),
           (0...1_000_000).contains(saved.resultLimit),
           (saved.overrides ?? [:]).values.allSatisfy({ (0...1_000_000).contains($0.resultLimit) }) {
            configuration = saved
        } else { configuration = CategoryScanConfiguration() }
    }

    func update(_ value: CategoryScanConfiguration) {
        guard (0...1_000_000).contains(value.resultLimit),
              (value.overrides ?? [:]).values.allSatisfy({ (0...1_000_000).contains($0.resultLimit) }), value != configuration else { return }
        configuration = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
    }

    func setRule(_ rule: CategoryScanRule, for category: FileCategory?) {
        var value = configuration
        if let category {
            var overrides = value.overrides ?? [:]
            overrides[category.rawValue] = rule
            value.overrides = overrides
        } else {
            value.usesCustomRoots = rule.usesCustomRoots
            value.paths = rule.paths
            value.resultLimit = rule.resultLimit
        }
        update(value)
    }

    func useDefault(for category: FileCategory) {
        var value = configuration
        value.overrides?.removeValue(forKey: category.rawValue)
        update(value)
    }

    func add(_ url: URL, for category: FileCategory? = nil) {
        _ = add([url], for: category)
    }

    @discardableResult
    func add(_ urls: [URL], for category: FileCategory? = nil) -> CategoryScanFolderAddition {
        var result = CategoryScanFolderAddition()
        var value = configuration.rule(for: category)
        var seen = Set(value.paths.map { FileItem.canonicalID(for: URL(fileURLWithPath: $0)) })
        for url in urls {
            var isDirectory: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                result.rejected += 1
                continue
            }
            let path = FileItem.canonicalID(for: url)
            guard seen.insert(path).inserted else { result.duplicates += 1; continue }
            value.paths.append(path)
            result.added += 1
        }
        if result.added > 0 { setRule(value, for: category) }
        return result
    }

    func remove(_ path: String, for category: FileCategory? = nil) {
        var value = configuration.rule(for: category)
        value.paths.removeAll { $0 == path }
        setRule(value, for: category)
    }
}

@MainActor
final class FSEngine: ObservableObject {
    let categoryScan: CategoryScanPreferences

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
    private var countCancellation: ScanCancellation?
    private var languageSubscription: AnyCancellable?
    private var volumeSubscriptions = Set<AnyCancellable>()

    private let foldersKey = "AddedFolderPaths"

    init(categoryScan: CategoryScanPreferences? = nil) {
        self.categoryScan = categoryScan ?? CategoryScanPreferences()
        loadAddedFolders()
        buildPlaces()
        buildVolumes()
        refreshAuthorizedRoots()
        self.categoryScan.$configuration.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleCategoryCount(force: true) }
            .store(in: &volumeSubscriptions)
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main).sink { [weak self] _ in
                    guard let self else { return }
                    self.buildVolumes()
                    self.scheduleCategoryCount(force: true)
                    NotificationCenter.default.post(name: .winFileVolumesChanged, object: self)
                }.store(in: &volumeSubscriptions)
        }
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
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                              options: [.skipHiddenVolumes]) ?? []
        var seen = Set<String>()
        volumes = mounted.compactMap { url in
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard normalized.path != "/", seen.insert(normalized.path).inserted else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return SidebarPlace(id: normalized.path, name: values?.volumeName ?? url.lastPathComponent,
                                url: normalized, kind: .volume, symbol: "externaldrive.fill",
                                isEjectable: values?.volumeIsEjectable ?? false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        !addFolders([url]).added.isEmpty
    }

    /// 保留用户选择的符号链接路径；路径标准化后去重，与现有收藏的身份规则一致。
    func containsFolder(_ url: URL) -> Bool {
        url.isFileURL && addedFolderPaths.contains(url.standardizedFileURL.path)
    }

    nonisolated static func isSidebarFolder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let normalized = url.standardizedFileURL
        guard normalized.pathExtension.lowercased() != "app",
              normalized.resolvingSymlinksInPath().pathExtension.lowercased() != "app" else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isReadableFile(atPath: normalized.path)
    }

    /// 所有入口共用校验；批量操作只保存、发布和安排统计一次。
    @discardableResult
    func addFolders(_ urls: [URL]) -> SidebarFolderAddition {
        var result = SidebarFolderAddition()
        var paths = Set(addedFolderPaths)
        for url in urls {
            guard Self.isSidebarFolder(url) else {
                result.rejectedCount += 1
                continue
            }
            let normalized = url.standardizedFileURL
            guard paths.insert(normalized.path).inserted else {
                result.duplicateCount += 1
                continue
            }
            result.added.append(normalized)
        }
        if !result.added.isEmpty {
            addedFolderPaths.append(contentsOf: result.added.map(\.path))
            saveAddedFolders()
            refreshAuthorizedRoots()
            scheduleCategoryCount()
        }
        return result
    }

    /// Existing favorites remain untouched, including paths seeded by older versions.
    func favoriteDisplayName(_ url: URL) -> String {
        if let standard = places.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            return standard.name
        }
        return FileManager.default.displayName(atPath: url.path)
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

    /// Each mounted volume is an explicit scan root, independent of the system-root traversal.
    var categoryRoots: [URL] {
        categoryRoots(for: nil)
    }

    func categoryRoots(for category: FileCategory?) -> [URL] {
        if let override = scopeOverrideForTesting { return override }
        let rule = categoryScan.configuration.rule(for: category)
        if rule.usesCustomRoots { return rule.paths.map { URL(fileURLWithPath: $0) } }
        let fm = FileManager.default
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                                           options: [.skipHiddenVolumes]) ?? []
        let localRoots = browsableRoots
        var roots: [URL] = []
        var seen = Set(localRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        for url in mounted {
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard normalized.path != "/", seen.insert(normalized.path).inserted else { continue }
            roots.append(normalized)
        }
        return roots + localRoots
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
        countCancellation?.cancel()
        let token = ScanCancellation()
        countCancellation = token
        countingCategories = true
        var groups: [[String]: [FileCategory]] = [:]
        var cachedRoots: [CategoryScanRule: [URL]] = [:]
        for category in FileCategory.sidebarOrder {
            let rule = categoryScan.configuration.rule(for: category)
            let roots: [URL]
            if let cached = cachedRoots[rule] { roots = cached }
            else { roots = categoryRoots(for: category); cachedRoots[rule] = roots }
            let paths = roots.map(\.path)
            groups[paths, default: []].append(category)
        }
        let scanGroups = groups
        countTask = Task { [weak self] in
            let counts = await Task.detached(priority: .utility) {
                var combined: [FileCategory: Int] = [:]
                for (paths, categories) in scanGroups {
                    if token.isCancelled { break }
                    let counts = FileSystemService.categoryCounts(under: paths.map { URL(fileURLWithPath: $0) }, cancelled: { token.isCancelled })
                    for category in categories { combined[category] = counts[category] }
                }
                return combined
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
            if item.isDirectory && !item.isSymlink {
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
    case unavailableSymlink(URL)
    case volumeUnavailable(URL)
    case notAuthorized(URL)
    case invalidName
    case nameExists(String)
    case recursiveTransfer(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let url):
            return String(format: WLocalizedString("error.notFound", comment: "路径不存在"), url.lastPathComponent)
        case .volumeUnavailable:
            return L("error.volumeUnavailable", "此磁盘当前未连接或未挂载。请连接后重试。")
        case .unavailableSymlink(let url):
            return L("error.symlinkTarget", "链接“%@”的目标不存在或无法访问。", url.lastPathComponent)
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

extension Notification.Name { static let winFileVolumesChanged = Notification.Name("WinFileVolumesChanged") }
