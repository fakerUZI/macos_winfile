// 浏览状态：导航历史、排序、选择、剪贴板、视图模式
import AppKit
import Combine
import Foundation
import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case thisPC
    case folder(URL)
    case applications
    case appData
    /// 安卓设备页（显示该设备的存储位置）
    case androidDevice(serial: String)
    case category(FileCategory)
}

enum ViewLayout: String {
    case details, icons
}

enum SortField: String, CaseIterable {
    case name, modified, type, size

    var localizedTitle: String {
        switch self {
        case .name: return NSLocalizedString("sort.name", comment: "按名称")
        case .modified: return NSLocalizedString("sort.modified", comment: "按修改日期")
        case .type: return NSLocalizedString("sort.type", comment: "按类型")
        case .size: return NSLocalizedString("sort.size", comment: "按大小")
        }
    }
}

struct ClipboardPayload {
    enum Mode { case copy, cut }
    var mode: Mode
    var urls: [URL]

    var localizedVerb: String {
        mode == .copy
            ? NSLocalizedString("clipboard.copied", comment: "已复制")
            : NSLocalizedString("clipboard.cut", comment: "已剪切")
    }
}

@MainActor
final class BrowserModel: ObservableObject {

    // 导航
    @Published var selection: SidebarSelection?
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var items: [FileItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchResults: [FileItem] = []
    /// 分类视图结果（在整个可浏览范围内按类型收集）
    @Published private(set) var categoryResults: [FileItem] = []
    @Published private(set) var isLoadingCategory = false

    // 主页（Home）
    @Published private(set) var quickAccess: [SidebarPlace] = []
    @Published private(set) var pinnedFolders: [URL] = []
    @Published private(set) var recentEntries: [RecentEntry] = []
    @Published private(set) var isLoadingHome = false
    @Published var showAllRecent = false

    // 此电脑（This PC）
    @Published private(set) var drives: [DriveInfo] = []
    @Published private(set) var isLoadingDrives = false
    /// 应用数据目录列表与加载状态
    @Published private(set) var appDataItems: [AppDataItem] = []
    @Published private(set) var isLoadingAppData = false
    @Published private(set) var needsFullDiskAccess = false
    /// 安卓目录条目（保留原始信息用于 adb 操作）
    @Published private(set) var androidEntries: [AndroidEntry] = []
    @Published private(set) var isLoadingAndroid = false
    /// 传输进度（上传/下载时非空）
    @Published var transferProgress: AndroidTransferProgress?
    /// 压缩/解压进度
    @Published var archiveProgress: ArchiveProgress?
    private var transferTask: Task<Void, Never>?

    // 视图选项
    @AppStorage("ViewLayout") var layoutRaw: String = ViewLayout.details.rawValue
    @AppStorage("ShowHiddenFiles") var showHidden: Bool = false
    @AppStorage("SortField") private var sortFieldRaw: String = SortField.name.rawValue
    @AppStorage("SortAscending") private var sortAscending: Bool = true

    // 剪贴板
    @Published private(set) var clipboard: ClipboardPayload?
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var categoryFilter: FileCategory?

    let engine: FSEngine
    private var backStack: [SidebarSelection] = []
    private var forwardStack: [SidebarSelection] = []
    private var listingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var categoryTask: Task<Void, Never>?
    private var homeTask: Task<Void, Never>?

    init(engine: FSEngine, startDirectory: URL?) {
        self.engine = engine
        if let start = startDirectory {
            currentDirectory = start
            selection = .folder(start)
            reload()
        }
    }

    var layout: ViewLayout {
        get { ViewLayout(rawValue: layoutRaw) ?? .details }
        set { layoutRaw = newValue.rawValue }
    }

    var sortField: SortField {
        get { SortField(rawValue: sortFieldRaw) ?? .name }
        set { sortFieldRaw = newValue.rawValue; applySort() }
    }

    var sortAscendingFlag: Bool {
        get { sortAscending }
        set { sortAscending = newValue; applySort() }
    }

    // MARK: - 数据源

    /// 当前展示的条目：分类视图 > 搜索结果 > 当前目录
    /// （主页与此电脑有自己的专用视图，不使用列表）
    var displayedItems: [FileItem] {
        if categoryFilter != nil { return categoryResults }
        if isSearching { return searchResults }
        return items
    }

    /// 是否处于分类视图
    var isCategoryView: Bool { categoryFilter != nil }

    /// 是否处于「应用数据」视图
    var isAppDataView: Bool {
        if case .appData = selection { return true }
        return false
    }

    /// 是否处于「安卓设备」视图
    var isAndroidDeviceView: Bool {
        if case .androidDevice = selection { return true }
        return false
    }

    /// 是否处于「应用程序」视图（同样不使用文件列表）
    var isApplicationsView: Bool {
        if case .applications = selection { return true }
        return false
    }

    /// 当前视图是否由文件列表承载。
    ///
    /// 主页、此电脑、应用数据、安卓设备、应用程序这些页面各自渲染自定义内容，
    /// `displayedItems` 对它们恒为空 —— 若不排除，空状态提示会叠在页面上。
    var showsFileList: Bool {
        !isHomeView && !isThisPCView && !isAppDataView
            && !isAndroidDeviceView && !isApplicationsView
    }

    /// 当前是否为安卓路径（安卓目录浏览由 adb 提供，与本地文件区分处理）
    var isAndroidPath: Bool {
        guard let dir = currentDirectory else { return false }
        return AndroidURL.isAndroid(dir)
    }

    /// 是否处于主页
    var isHomeView: Bool {
        if case .home = selection { return true }
        return false
    }

    /// 是否处于「此电脑」
    var isThisPCView: Bool {
        if case .thisPC = selection { return true }
        return false
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// 分类视图是否为空（用于提示文案）
    var categoryIsEmpty: Bool { categoryFilter != nil && !isLoadingCategory && categoryResults.isEmpty }

    var canGoUp: Bool {
        guard let dir = currentDirectory else { return false }
        return dir.path != "/" && !dir.path.isEmpty
    }

    var selectedItems: [FileItem] {
        displayedItems.filter { selectedIDs.contains($0.id) }
    }

    /// 选中数量。
    ///
    /// 界面各处统一用它取数：此前状态栏用 selectedIDs.count、检查器用
    /// selectedItems.count，两者在 Table 高亮与模型状态短暂不同步时会显示
    /// 不同数字（用户实测遇到 14 与 16 并存）。统一后不会再有这种矛盾。
    var selectedCount: Int { selectedItems.count }

    var effectiveDirectory: URL? {
        currentDirectory ?? engine.authorizedRoots.first
    }

    var windowSubtitle: String {
        switch selection {
        case .home:
            return L("view.home", "主页")
        case .thisPC:
            return L("view.thisPC", "此电脑")
        case .applications:
            return L("view.applications", "应用程序")
        case .appData:
            return L("view.appData", "应用数据")
        case .androidDevice(let serial):
            return AndroidDeviceRegistry.shared.device(serial: serial)?.displayName
                ?? L("view.androidDevice", "安卓设备")
        case .category(let category):
            return category.localizedName
        case .folder(let url):
            return url.lastPathComponent
        case nil:
            return ""
        }
    }

    // MARK: - 导航

    func navigate(to target: SidebarSelection, recordHistory: Bool = true) {
        if recordHistory, let current = selection, current != target {
            backStack.append(current)
            forwardStack.removeAll()
        }
        TabDiagnostics.shared.record("navigate", detail: "目标=\(describe(target)) 旧=\(describe(selection))")
        selection = target
        switch target {
        case .home:
            loadHome()
        case .thisPC:
            loadThisPC()
        case .folder(let url):
            load(directory: url)
        case .applications:
            loadApplications()
        case .appData:
            loadAppData()
        case .androidDevice(let serial):
            loadAndroidDevice(serial: serial)
        case .category(let category):
            categoryFilter = category
            loadCategory(category)
        }
    }

    func selectFolder(_ url: URL) {
        categoryFilter = nil
        navigate(to: .folder(url))
        TabDiagnostics.shared.record("selectFolder.done",
                                     detail: "目录=\(currentDirectory?.lastPathComponent ?? "-") 选择=\(describe(selection))")
    }

    /// 便于诊断：把选中项描述成短字符串
    private func describe(_ value: SidebarSelection?) -> String {
        switch value {
        case .home: return "主页"
        case .thisPC: return "此电脑"
        case .applications: return "应用程序"
        case .appData: return "应用数据"
        case .androidDevice(let serial): return "安卓设备:\(serial)"
        case .category(let c): return "分类:\(c.rawValue)"
        case .folder(let url): return "文件夹:\(url.lastPathComponent)"
        case nil: return "无"
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = selection { forwardStack.append(current) }
        selection = nil
        navigate(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selection { backStack.append(current) }
        selection = nil
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard let dir = currentDirectory, canGoUp else { return }
        selectFolder(dir.deletingLastPathComponent())
    }

    // MARK: - 加载

    func reload() {
        guard let dir = currentDirectory else {
            if case .applications = selection { loadApplications() }
            return
        }
        load(directory: dir, resetCategory: false)
    }

    private func load(directory: URL, resetCategory: Bool = true) {
        // 安卓路径走 adb 列目录（本地 FileManager 无法访问设备文件）
        if AndroidURL.isAndroid(directory) {
            loadAndroidDirectory(directory)
            return
        }
        listingTask?.cancel()
        categoryTask?.cancel()
        currentDirectory = directory
        isSearching = false
        searchResults = []
        if resetCategory {
            categoryFilter = nil
            categoryResults = []
            isLoadingCategory = false
        }
        isLoadingHome = false
        isLoadingDrives = false
        isBusy = true
        let showHidden = showHidden
        let engine = self.engine
        listingTask = Task { [weak self] in
            var loaded: [FileItem] = []
            var failure: String?
            do {
                loaded = try await Task.detached(priority: .userInitiated) {
                    try FileSystemService.list(directory, showHidden: showHidden)
                }.value
            } catch {
                failure = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items = loaded
                self.selectedIDs = self.selectedIDs.filter { id in loaded.contains { $0.id == id } }
                self.isBusy = false
                if let failure {
                    self.errorMessage = failure
                    self.statusMessage = failure
                } else {
                    self.updateStatus()
                }
            }
        }
    }

    // MARK: - 主页（Home）

    func loadHome() {
        homeTask?.cancel()
        if case .home = selection {} else { selection = .home }
        categoryFilter = nil
        categoryResults = []
        isSearching = false
        searchResults = []
        currentDirectory = nil
        items = []
        selectedIDs = []
        isLoadingHome = true
        isBusy = true
        statusMessage = L("status.loadingHome", "正在整理主页…")
        refreshFavorites()
        let roots = engine.browsableRoots
        homeTask = Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                PlacesService.recentEntries(under: roots, limit: 40)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recentEntries = entries
                self.isLoadingHome = false
                self.isBusy = false
                self.quickAccess = PlacesService.quickAccessFolders()
                self.statusMessage = entries.isEmpty
                    ? L("status.homeEmpty", "最近没有修改或打开过文件")
                    : L("status.homeCount", "最近使用 %d 项", entries.count)
            }
        }
    }

    /// 刷新收藏夹与快速访问（固定/取消固定后调用）
    func refreshFavorites() {
        pinnedFolders = FavoritesStore.shared.pinnedFolders
        quickAccess = PlacesService.quickAccessFolders()
    }

    func togglePin(_ url: URL) {
        FavoritesStore.shared.togglePin(url)
        refreshFavorites()
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedFolders.contains { $0.path == url.standardizedFileURL.path }
    }

    /// 打开主页里的条目（会记录到「最近打开」）
    func openRecent(_ entry: RecentEntry) {
        activate(entry.item)
    }

    func clearRecentHistory() {
        FavoritesStore.shared.clearOpened()
        loadHome()
    }

    // MARK: - 此电脑（This PC）

    /// 载入「应用数据」列表。
    ///
    /// 说明：读取其它应用的容器需要「完整磁盘访问权限」，
    /// 该权限只能由用户在系统设置中手动授予。未授权时相关目录不可读，
    /// 这里会置起 needsFullDiskAccess 以便界面给出明确指引。
    func loadAppData() {
        homeTask?.cancel()
        if case .appData = selection {} else { selection = .appData }
        categoryFilter = nil
        categoryResults = []
        isSearching = false
        searchResults = []
        currentDirectory = nil
        items = []
        selectedIDs = []
        isLoadingAppData = true
        isBusy = true
        statusMessage = L("status.scanningAppData", "正在扫描应用数据目录…")

        homeTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                AppDataService.scan()
            }.value
            let sufficient = await Task.detached(priority: .userInitiated) {
                AppDataService.hasSufficientAccess(scanned)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.needsFullDiskAccess = !sufficient
            self.appDataItems = scanned
            self.isLoadingAppData = false
            self.isBusy = false
            let readable = scanned.filter { $0.isReadable }.count
            self.statusMessage = sufficient
                ? L("status.appDataCount", "共 %d 个应用数据目录（%d 个可浏览）", scanned.count, readable)
                : L("status.appDataNoAccess", "共 %d 个应用数据目录（其中 %d 个需要完整磁盘访问权限）",
                    scanned.count, scanned.count - readable)
        }
    }

    /// 载入「安卓设备」页：列出该设备的存储位置
    // MARK: - 安卓文件浏览

    /// 载入安卓目录（经 adb 列目录）
    func loadAndroidDirectory(_ url: URL) {
        guard let (serial, path) = AndroidURL.split(url) else {
            errorMessage = L("android.error.badURL", "无法解析设备路径：%@", url.absoluteString)
            return
        }
        homeTask?.cancel()
        categoryFilter = nil
        categoryResults = []
        isSearching = false
        searchResults = []
        currentDirectory = url
        selectedIDs = []
        isLoadingAndroid = true
        isBusy = true
        statusMessage = L("status.androidLoading", "正在读取设备目录…")
        let showHidden = self.showHidden

        homeTask = Task { [weak self] in
            let result: Result<[AndroidEntry], Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let service = AndroidFileService(serial: serial)
                    do {
                        var entries = try service.list(path)
                        if !showHidden {
                            entries = entries.filter { !$0.name.hasPrefix(".") }
                        }
                        continuation.resume(returning: .success(entries))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let entries):
                self.androidEntries = entries
                self.items = entries.map { $0.asFileItem() }
                self.applySort()
                self.isLoadingAndroid = false
                self.isBusy = false
                self.statusMessage = L("status.androidCount", "%d 个项目", entries.count)
            case .failure(let error):
                self.androidEntries = []
                self.items = []
                self.isLoadingAndroid = false
                self.isBusy = false
                self.errorMessage = error.localizedDescription
                self.statusMessage = L("status.androidFailed", "读取失败")
            }
        }
    }

    // MARK: - 跳转到文件所在目录

    /// 当前视图是否为「跨目录聚合」：分类与搜索结果来自多个目录，
    /// 因此需要「打开所在文件夹」才能回到文件的真实位置。
    var isAggregatedView: Bool { isCategoryView || isSearching }

    /// 跳到指定文件所在的文件夹，并把它选中。
    ///
    /// 用途：分类视图与搜索结果里的文件不在当前目录下，
    /// 用户需要一键回到它的真实位置（Windows 的「打开文件位置」）。
    func openContainingFolder(of item: FileItem) {
        if AndroidURL.isAndroid(item.url) {
            errorMessage = L("android.hint.revealUnsupported",
                             "设备上的文件无法在访达中显示。如需在本机处理，请先复制到本地文件夹。")
            return
        }
        let directory = item.url.deletingLastPathComponent()
        pendingSelectionID = item.id
        selectFolder(directory)
    }

    /// 待选中项：跳到目录后由列表/网格读取并滚动定位，用完即清
    @Published var pendingSelectionID: String?

    /// 取出并清空待选中项
    func consumePendingSelection() -> String? {
        defer { pendingSelectionID = nil }
        return pendingSelectionID
    }

    /// 打开安卓设备上的项目（文件夹进入，文件用系统默认方式打开不支持 → 提示）
    /// 安卓端删除选中项
    func deleteAndroidSelection() {
        let entries = selectedAndroidEntries
        guard !entries.isEmpty else { return }
        guard let (serial, _) = AndroidURL.split(currentDirectory ?? entries[0].url) else { return }
        runAndroidOperation(L("status.deleting", "正在删除…")) { service in
            for entry in entries { try service.remove(entry.path) }
        }
    }

    /// 安卓端重命名
    func renameAndroid(_ entry: AndroidEntry, to newName: String) {
        guard let (serial, _) = AndroidURL.split(entry.url) else { return }
        runAndroidOperation(L("status.renaming", "正在重命名…")) { service in
            try service.rename(entry.path, to: newName)
        }
    }

    /// 安卓端新建文件夹 / 空文件
    func createAndroidFolder(named name: String) {
        guard let directory = currentDirectory,
              let (_, path) = AndroidURL.split(directory) else { return }
        let target = path.hasSuffix("/") ? path + name : path + "/" + name
        runAndroidOperation(L("status.creating", "正在创建…")) { service in
            try service.createFolder(at: target)
        }
    }

    func createAndroidFile(named name: String) {
        guard let directory = currentDirectory,
              let (_, path) = AndroidURL.split(directory) else { return }
        let target = path.hasSuffix("/") ? path + name : path + "/" + name
        runAndroidOperation(L("status.creating", "正在创建…")) { service in
            try service.createEmptyFile(at: target)
        }
    }

    // MARK: - 压缩与解压

    /// 选中的压缩包（用于「解压到当前文件夹」菜单项）
    var selectedArchives: [FileItem] {
        selectedItems.filter { !$0.isDirectory && ArchiveService.isArchive($0.url) }
    }

    var canExtract: Bool { !selectedArchives.isEmpty && !isAndroidPath }

    var canCompress: Bool { !selectedItems.isEmpty && !isAndroidPath }

    /// 压缩选中项到当前目录
    func compressSelection() {
        guard canCompress, let directory = currentDirectory else { return }
        let urls = selectedItems.map(\.url)
        let name = ArchiveService.defaultArchiveName(for: urls)
        archiveProgress = ArchiveProgress(name: name, isCompressing: true)
        let engine = self.engine
        Task { [weak self] in
            var failure: String?
            do {
                let target = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.compress(urls, to: directory, name: name)
                }.value
                await MainActor.run { [weak self] in
                    self?.statusMessage = L("status.compressed", "已压缩为 %@", target.lastPathComponent)
                }
                _ = engine
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.archiveProgress = nil
                if let failure { self.errorMessage = failure } else { self.reload() }
            }
        }
    }

    /// 解压选中的压缩包到当前目录
    func extractSelection() {
        guard let archive = selectedArchives.first, let directory = currentDirectory else { return }
        archiveProgress = ArchiveProgress(name: archive.name, isCompressing: false)
        Task { [weak self] in
            var failure: String?
            var created: [URL] = []
            do {
                created = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.extract(archive.url, to: directory)
                }.value
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.archiveProgress = nil
                if let failure {
                    self.errorMessage = failure
                } else {
                    self.statusMessage = created.isEmpty
                        ? L("status.extracted", "已解压")
                        : L("status.extractedCount", "已解压 %d 项", created.count)
                    self.reload()
                }
            }
        }
    }

    /// 把选中的安卓条目下载到本机（弹出目录选择）
    func downloadSelectedToLocalFolder() {
        let entries = selectedAndroidEntries
        guard !entries.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = L("android.chooseSaveFolder", "下载到此文件夹")
        panel.directoryURL = FileSystemService.realHomeDirectory()
            .appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let target = panel.url else { return }
        // 逐个下载（共享同一个进度显示）
        for (index, entry) in entries.enumerated() {
            downloadFromAndroid(entry, to: target, announce: index == entries.count - 1)
        }
    }

    /// 把剪贴板内容粘贴到当前安卓目录
    ///
    /// - 剪贴板是本机文件 → 上传
    /// - 剪贴板是安卓文件 → 设备内复制/移动
    func pasteIntoAndroid() {
        guard let directory = currentDirectory,
              let (serial, remotePath) = AndroidURL.split(directory) else { return }

        // 情况一：本机文件 → 上传
        let localURLs = (clipboard?.urls ?? []).filter { !AndroidURL.isAndroid($0) }
        if !localURLs.isEmpty {
            uploadToAndroid(localURLs, to: directory)
            return
        }

        // 情况二：安卓文件 → 设备内复制/移动
        guard let payload = androidClipboard else { return }
        let move = payload.isCut
        transferProgress = AndroidTransferProgress(name: payload.entry.name,
                                                   direction: .upload)
        transferTask = Task { [weak self] in
            let error: Error? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let service = AndroidFileService(serial: serial)
                    do {
                        if move {
                            try service.move(payload.entry.path, to: remotePath)
                        } else {
                            try service.copy(payload.entry.path, to: remotePath)
                        }
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error)
                    }
                }
            }
            guard let self else { return }
            self.transferProgress = nil
            if let error {
                self.errorMessage = error.localizedDescription
                self.statusMessage = L("status.pasteFailed", "粘贴失败")
            } else {
                self.statusMessage = move
                    ? L("status.moved", "已移动")
                    : L("status.copied", "已复制")
                if move { self.androidClipboard = nil }
                if let dir = self.currentDirectory { self.loadAndroidDirectory(dir) }
            }
        }
    }

    /// 在后台执行一次安卓操作，完成后刷新目录
    private func runAndroidOperation(_ title: String,
                                     _ body: @escaping (AndroidFileService) throws -> Void) {
        guard let directory = currentDirectory,
              let (serial, _) = AndroidURL.split(directory) else { return }
        statusMessage = title
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            let error: Error? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try body(AndroidFileService(serial: serial))
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error)
                    }
                }
            }
            guard let self else { return }
            if let error {
                self.errorMessage = error.localizedDescription
            } else if let dir = self.currentDirectory {
                self.loadAndroidDirectory(dir)
            }
        }
    }

    /// 安卓内部的剪贴板（与本机剪贴板分开，避免混淆）
    struct AndroidClipboardPayload {
        let entry: AndroidEntry
        let isCut: Bool
    }
    @Published var androidClipboard: AndroidClipboardPayload?

    /// 当前选中的安卓条目
    var selectedAndroidEntries: [AndroidEntry] {
        let paths = Set(selectedItems.map { $0.url.path })
        return androidEntries.filter { paths.contains($0.path) }
    }

    func activateAndroid(_ entry: AndroidEntry) {
        if entry.isDirectory {
            selectFolder(entry.url)
        } else {
            errorMessage = L("android.hint.downloadFirst",
                             "安卓上的文件需要先下载到本机才能打开。请复制到本地目录后再打开。")
        }
    }

    /// 把安卓文件/目录下载到本地目录（带进度）
    func downloadFromAndroid(_ entry: AndroidEntry, to localDirectory: URL,
                             announce: Bool = true) {
        guard let (serial, _) = AndroidURL.split(entry.url) else { return }
        transferProgress = AndroidTransferProgress(name: entry.name, direction: .download)
        let service = AndroidFileService(serial: serial)
        transferTask = Task { [weak self] in
            let error: Error? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try service.pull(remote: entry.path, to: localDirectory) { fraction in
                            Task { @MainActor in self?.transferProgress?.fraction = fraction }
                        }
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error)
                    }
                }
            }
            guard let self else { return }
            self.transferProgress = nil
            if let error {
                self.errorMessage = error.localizedDescription
                self.statusMessage = L("status.downloadFailed", "下载失败")
            } else {
                self.statusMessage = L("status.downloaded", "已下载：%@", entry.name)
                if announce { self.reload() }
            }
        }
    }

    /// 把本地文件/目录上传到安卓目录（带进度）
    func uploadToAndroid(_ urls: [URL], to androidDirectory: URL) {
        guard let (serial, remotePath) = AndroidURL.split(androidDirectory) else { return }
        let service = AndroidFileService(serial: serial)
        transferProgress = AndroidTransferProgress(
            name: urls.map(\.lastPathComponent).joined(separator: "、"), direction: .upload)
        transferTask = Task { [weak self] in
            var failed: Error?
            for url in urls {
                let error: Error? = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try service.push(local: url, to: remotePath) { fraction in
                                Task { @MainActor in self?.transferProgress?.fraction = fraction }
                            }
                            continuation.resume(returning: nil)
                        } catch {
                            continuation.resume(returning: error)
                        }
                    }
                }
                if let error { failed = error; break }
            }
            guard let self else { return }
            self.transferProgress = nil
            if let failed {
                self.errorMessage = failed.localizedDescription
                self.statusMessage = L("status.uploadFailed", "上传失败")
            } else {
                self.statusMessage = L("status.uploaded", "已上传 %d 项", urls.count)
                self.loadAndroidDirectory(androidDirectory)
            }
        }
    }

    func loadAndroidDevice(serial: String) {
        homeTask?.cancel()
        if case .androidDevice = selection {} else { selection = .androidDevice(serial: serial) }
        categoryFilter = nil
        categoryResults = []
        isSearching = false
        searchResults = []
        currentDirectory = nil
        items = []
        selectedIDs = []
        isBusy = false
        statusMessage = L("status.androidDevice", "正在读取设备存储…")
    }

    func loadThisPC() {
        homeTask?.cancel()
        if case .thisPC = selection {} else { selection = .thisPC }
        categoryFilter = nil
        categoryResults = []
        isSearching = false
        searchResults = []
        currentDirectory = nil
        items = []
        selectedIDs = []
        isLoadingDrives = true
        isBusy = true
        statusMessage = L("status.loadingDrives", "正在读取磁盘信息…")
        homeTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                PlacesService.drives()
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.drives = found
                self.isLoadingDrives = false
                self.isBusy = false
                self.statusMessage = L("status.driveCount", "%d 个驱动器", found.count)
            }
        }
    }

    @discardableResult
    func eject(_ drive: DriveInfo) -> Bool {
        let ok = PlacesService.eject(drive)
        if ok {
            statusMessage = L("status.ejected", "已弹出「%@」", drive.name)
            loadThisPC()
        } else {
            errorMessage = L("error.ejectFailed", "无法弹出「%@」", drive.name)
        }
        return ok
    }

    /// 记录「最近打开」——由打开动作调用
    func noteOpened(_ url: URL) {
        FavoritesStore.shared.recordOpened(url)
    }

    /// 在整个可浏览范围内按类型收集文件（Windows 式「按类型分类」视图）
    func loadCategory(_ category: FileCategory) {
        categoryTask?.cancel()
        categoryFilter = category
        isSearching = false
        searchResults = []
        categoryResults = []
        isLoadingCategory = true
        isBusy = true
        statusMessage = L("status.categoryLoading", "正在归类「%@」…", category.localizedName)
        let roots = engine.browsableRoots
        categoryTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                FileSystemService.categoryFiles(category, under: roots)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.categoryFilter == category else { return }
                self.categoryResults = found
                self.isLoadingCategory = false
                self.isBusy = false
                self.selectedIDs = []
                if found.isEmpty {
                    self.statusMessage = L("status.categoryEmpty", "%@：没有找到文件", category.localizedName)
                } else {
                    let truncated = found.count >= FileSystemService.categoryBudget
                    let key = truncated ? "status.categoryCount.truncated" : "status.categoryCount"
                    let fallback = truncated
                        ? "%@：显示前 %d 个（已达上限，可在文件夹中查看更精确的结果）"
                        : "%@：%d 个文件（来自整个浏览范围）"
                    self.statusMessage = L(key, fallback, category.localizedName, found.count)
                }
            }
        }
    }

    func loadApplications() {
        listingTask?.cancel()
        categoryTask?.cancel()
        currentDirectory = nil
        isSearching = false
        categoryFilter = nil
        categoryResults = []
        isLoadingCategory = false
        isBusy = true
        let roots = engine.authorizedRoots
        listingTask = Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) {
                FileSystemService.listApplications(allowedRoots: roots)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items = apps
                self.selectedIDs = []
                self.isBusy = false
                self.statusMessage = String(format: NSLocalizedString("status.appCount", comment: "应用数量"), apps.count)
            }
        }
    }

    func toggleHiddenFiles() {
        showHidden.toggle()
        reload()
    }

    func setLayout(_ newLayout: ViewLayout) {
        layout = newLayout
    }

    func setCategoryFilter(_ category: FileCategory?) {
        if let category {
            selection = .category(category)
            loadCategory(category)
        } else {
            categoryFilter = nil
            categoryResults = []
            isLoadingCategory = false
            if let dir = currentDirectory {
                selection = .folder(dir)
                load(directory: dir)
            }
        }
    }

    // MARK: - 排序

    private func applySort() {
        items = FileSystemService.sort(items, field: sortField, ascending: sortAscending)
    }

    // MARK: - 选择

    func select(_ item: FileItem, extend: Bool = false, toggle: Bool = false) {
        if toggle {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
        } else if extend {
            selectedIDs.insert(item.id)
        } else {
            selectedIDs = [item.id]
        }
    }

    func selectAll() {
        selectedIDs = Set(displayedItems.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    // MARK: - 操作

    func activate(_ item: FileItem) {
        TabDiagnostics.shared.record("activate", detail: "项目=\(item.name) 目录=\(item.isDirectory)")
        // 安卓条目不能交给 NSWorkspace（android:// 不是本机可打开的地址）
        if AndroidURL.isAndroid(item.url) {
            if let entry = androidEntries.first(where: { $0.path == item.url.path }) {
                activateAndroid(entry)
            }
            return
        }
        // .app 包双击启动；普通文件夹进入浏览
        if item.isBundle && item.url.pathExtension.lowercased() == "app" {
            noteOpened(item.url)
            engine.open(item)
            return
        }
        if item.isDirectory {
            selectFolder(item.url)
            return
        }
        noteOpened(item.url)
        engine.open(item)
    }

    func openSelection() {
        for item in selectedItems { activate(item) }
    }

    func openSelection(withApplicationAt appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        for item in selectedItems {
            NSWorkspace.shared.open([item.url], withApplicationAt: appURL, configuration: config) { _, error in
                if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
            }
        }
    }

    func revealSelection() {
        // 安卓条目在访达里没有对应位置，只能提示（或定位到本机下载目录）
        if isAndroidPath {
            errorMessage = L("android.hint.revealUnsupported",
                             "设备上的文件无法在访达中显示。如需在本机处理，请先复制到本地文件夹。")
            return
        }
        engine.revealInFinder(selectedItems)
    }

    func copySelectionToClipboard() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        // 安卓条目无法写入系统剪贴板（不是本地文件），单独记录
        if isAndroidPath {
            if let entry = selectedAndroidEntries.first {
                androidClipboard = AndroidClipboardPayload(entry: entry, isCut: false)
                clipboard = nil
                statusMessage = L("clipboard.copied", "已复制")
            }
            return
        }
        clipboard = ClipboardPayload(mode: .copy, urls: urls)
        // 同时写入系统剪贴板，可直接粘到其它应用
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        statusMessage = String(format: NSLocalizedString("status.copied", comment: "已复制到剪贴板"), urls.count)
    }

    func cutSelectionToClipboard() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        if isAndroidPath {
            if let entry = selectedAndroidEntries.first {
                androidClipboard = AndroidClipboardPayload(entry: entry, isCut: true)
                clipboard = nil
                statusMessage = L("clipboard.cut", "已剪切")
            }
            return
        }
        clipboard = ClipboardPayload(mode: .cut, urls: urls)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        statusMessage = String(format: NSLocalizedString("status.cut", comment: "已剪切到剪贴板"), urls.count)
    }

    /// 复制选中的文件路径文本到剪贴板
    func copyPathToClipboard(includeDirectory: Bool = false) {
        let urls = selectedItems.map { includeDirectory ? $0.url.deletingLastPathComponent() : $0.url }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        statusMessage = NSLocalizedString("status.pathCopied", comment: "路径已复制")
    }

    func copyNameToClipboard() {
        let names = selectedItems.map(\.name)
        guard !names.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
        statusMessage = NSLocalizedString("status.nameCopied", comment: "名称已复制")
    }

    func paste() {
        // 目标是安卓目录时走 adb（上传或设备内复制/移动）
        if isAndroidPath {
            pasteIntoAndroid()
            return
        }
        guard let clipboard, let directory = currentDirectory else { return }
        let urls = clipboard.urls
        let mode: FSEngine.TransferMode = clipboard.mode == .copy ? .copy : .move
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            var failure: String?
            do {
                let items = urls.compactMap { url -> FileItem? in
                    FileItem(url: url, resourceKeys: FSEngine.resourceKeys, showHidden: true)
                }
                _ = try self.engine.transfer(items, to: directory, mode: mode)
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if let failure {
                    self.errorMessage = failure
                } else {
                    let verb = mode == .copy
                        ? NSLocalizedString("action.pasted", comment: "已粘贴")
                        : NSLocalizedString("action.moved", comment: "已移动")
                    self.statusMessage = "\(verb) \(urls.count) \(NSLocalizedString("unit.items", comment: "项"))"
                    if mode == .move { self.clipboard = nil }
                }
                self.reload()
            }
        }
    }

    func deleteSelection(permanently: Bool = false) {
        let items = selectedItems
        guard !items.isEmpty else { return }
        // 安卓条目走 adb 删除（本地 FileManager 不适用）
        if isAndroidPath {
            deleteAndroidSelection()
            return
        }
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            var failure: String?
            do {
                if permanently {
                    for item in items { try FileManager.default.removeItem(at: item.url) }
                } else {
                    try self.engine.moveToTrash(items)
                }
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if let failure {
                    self.errorMessage = failure
                } else {
                    self.statusMessage = String(format: NSLocalizedString("status.deleted", comment: "已删除"), items.count)
                    self.selectedIDs.removeAll()
                }
                self.reload()
            }
        }
    }

    func duplicateSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            var failure: String?
            do { _ = try self.engine.duplicate(items) } catch { failure = error.localizedDescription }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if let failure { self.errorMessage = failure } else {
                    self.statusMessage = String(format: NSLocalizedString("status.duplicated", comment: "已生成副本"), items.count)
                }
                self.reload()
            }
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        // 安卓条目走 adb 重命名
        if AndroidURL.isAndroid(item.url),
           let entry = androidEntries.first(where: { $0.path == item.url.path }) {
            renameAndroid(entry, to: newName)
            return
        }
        do {
            _ = try engine.rename(item, to: newName)
            statusMessage = NSLocalizedString("status.renamed", comment: "已重命名")
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(named name: String) {
        if isAndroidPath {
            createAndroidFolder(named: name)
            return
        }
        guard let directory = currentDirectory else { return }
        do {
            let url = try engine.createFolder(in: directory, named: name)
            statusMessage = String(format: NSLocalizedString("status.created", comment: "已创建"), url.lastPathComponent)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createTextFile(named name: String, contents: String = "") {
        guard let directory = currentDirectory else { return }
        do {
            let url = try engine.createTextFile(in: directory, named: name, contents: contents)
            statusMessage = String(format: NSLocalizedString("status.created", comment: "已创建"), url.lastPathComponent)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 把系统剪贴板里的文字保存成文件
    func saveClipboardTextAsFile() -> String? {
        guard let directory = currentDirectory else { return nil }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? "剪贴板文本"
        let safe = firstLine.replacingOccurrences(of: "/", with: "_").prefix(40)
        do {
            let url = try engine.createTextFile(in: directory, named: "\(safe).txt", contents: text)
            statusMessage = String(format: NSLocalizedString("status.created", comment: "已创建"), url.lastPathComponent)
            reload()
            return url.lastPathComponent
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    var clipboardHasText: Bool {
        NSPasteboard.general.string(forType: .string)?.isEmpty == false
    }

    // MARK: - 搜索

    func search(_ text: String) {
        searchTask?.cancel()
        categoryFilter = nil
        categoryResults = []
        isLoadingCategory = false
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let root = currentDirectory else {
            isSearching = false
            searchResults = []
            updateStatus()
            return
        }
        isSearching = true
        isBusy = true
        let engine = self.engine
        searchTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                FileSystemService.search(under: root, matching: needle)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.searchResults = found
                self.isBusy = false
                self.statusMessage = String(format: NSLocalizedString("status.searchResult", comment: "搜索结果"), found.count, needle)
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        isSearching = false
        searchResults = []
        updateStatus()
    }

    // MARK: - 状态

    private func updateStatus() {
        let folders = items.filter(\.isContainer).count
        let files = items.count - folders
        statusMessage = String(format: NSLocalizedString("status.itemCount", comment: "项目统计"), items.count, folders, files)
    }

    var selectionSummary: String {
        let selected = selectedItems
        guard !selected.isEmpty else { return "" }
        let bytes = selected.compactMap(\.size).reduce(Int64(0), +)
        if selected.count == 1 {
            return selected[0].sizeText
        }
        return FileItem.formatSize(bytes)
    }

    /// 当前文件夹的磁盘信息
    func volumeInfo(for url: URL) -> (free: String, total: String)? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (FileItem.formatSize(free),
                FileItem.formatSize(Int64(total)))
    }
}
