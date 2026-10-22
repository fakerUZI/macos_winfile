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
    case weChatCleanup
    case storageCleanup
    /// 安卓设备页（显示该设备的存储位置）
    case androidDevice(serial: String)
    case category(FileCategory)
}

enum CleanupSection: String, Codable {
    case general, software
}

enum ViewLayout: String {
    case details, icons
}

enum SortField: String, CaseIterable {
    case name, modified, type, size

    var localizedTitle: String {
        switch self {
        case .name: return WLocalizedString("sort.name", comment: "按名称")
        case .modified: return WLocalizedString("sort.modified", comment: "按修改日期")
        case .type: return WLocalizedString("sort.type", comment: "按类型")
        case .size: return WLocalizedString("sort.size", comment: "按大小")
        }
    }
}

struct ClipboardPayload {
    enum Mode { case copy, cut }
    var mode: Mode
    var urls: [URL]

    var localizedVerb: String {
        mode == .copy
            ? WLocalizedString("clipboard.copied", comment: "已复制")
            : WLocalizedString("clipboard.cut", comment: "已剪切")
    }
}

@MainActor
final class BrowserModel: ObservableObject {
    /// Route new-tab navigation through the window that owns this model.
    weak var tabManager: TabManager?

    // 导航
    @Published var selection: SidebarSelection?
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var items: [FileItem] = []
    @Published private var fileSelectedIDs: Set<String> = []
    var selectedIDs: Set<String> {
        get {
            if let store = activeStorageCleanup { return store.selection }
            return isWeChatCleanupView ? weChatCleanup.selection : fileSelectedIDs
        }
        set {
            if let store = activeStorageCleanup { store.selection = newValue }
            else if isWeChatCleanupView { weChatCleanup.selection = newValue }
            else { fileSelectedIDs = newValue }
        }
    }
    @Published private(set) var isSearching = false
    @Published private(set) var searchResults: [FileItem] = []
    @Published private(set) var searchQuery = ""
    @Published var searchCriteria = FileSearchCriteria()
    @Published private(set) var scanReport = FileScanReport()
    private var searchLimit = 400
    private var categoryLimit = 800
    private var categoryDepth = 4
    private var scanEntryLimit = 100_000
    private var searchCancellation: ScanCancellation?
    private var categoryCancellation: ScanCancellation?
    private var searchID = UUID()
    private var categoryID = UUID()
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
    /// 安卓目录条目（保留原始信息用于 MTP 操作）
    @Published private(set) var androidEntries: [AndroidEntry] = []
    @Published private(set) var isLoadingAndroid = false
    /// 传输进度（上传/下载时非空）
    @Published var transferProgress: AndroidTransferProgress?
    /// 压缩/解压进度
    @Published var archiveProgress: ArchiveProgress?
    private var archiveCancellation: ScanCancellation?
    private var archiveID = UUID()
    private var transferTask: Task<Void, Never>?
    private var transferCancellation: ScanCancellation?
    private var transferSerial: String?
    @Published private(set) var isOpeningAndroidFile = false
    private var androidOpenTask: Task<Void, Never>?
    private var androidOpenCancellation: ScanCancellation?
    private var androidOpenID = UUID()
    private var androidOpenSerial: String?
    private var androidConnectionIdentity: String?
    private var androidDevicesSubscription: AnyCancellable?
    private let androidRegistry: AndroidDeviceRegistry
    private let androidOpenService: AndroidOpenService
    private let androidOpenHandler: (([URL], Bool) -> Void)?
    private let androidVideoHandler: ((AndroidEntry, Bool, ScanCancellation) async throws -> Void)?
    @Published private(set) var fileTransferProgress: FileTransferProgress?
    @Published var lastTransferOutcome: FileTransferOutcome?
    private var fileTransferCancellation: ScanCancellation?
    private var fileTransferID = UUID()
    private var directoryWatcher: DirectoryWatcher?
    private var watchedDirectory: URL?
    private var watchesChanges = false
    private var directoryRefreshTask: Task<Void, Never>?
    private var filesChangedSubscription: AnyCancellable?

    // 视图选项
    @Published var layoutRaw: String = UserDefaults.standard.string(forKey: "ViewLayout") ?? ViewLayout.details.rawValue { didSet { UserDefaults.standard.set(layoutRaw, forKey: "ViewLayout") } }
    @Published var showHidden: Bool = UserDefaults.standard.bool(forKey: "ShowHiddenFiles") { didSet { UserDefaults.standard.set(showHidden, forKey: "ShowHiddenFiles") } }
    @Published private var sortFieldRaw: String = UserDefaults.standard.string(forKey: "SortField") ?? SortField.name.rawValue { didSet { UserDefaults.standard.set(sortFieldRaw, forKey: "SortField") } }
    @Published private var sortAscending: Bool = (UserDefaults.standard.object(forKey: "SortAscending") as? Bool) ?? true { didSet { UserDefaults.standard.set(sortAscending, forKey: "SortAscending") } }

    // 剪贴板
    let clipboardStore: FileClipboard
    var clipboard: ClipboardPayload? { clipboardStore.localPayload }
    var canPaste: Bool { !isCategoryView && !isBusy && archiveProgress == nil && fileTransferProgress == nil && transferProgress == nil && currentDirectory != nil && (clipboard != nil || (isAndroidPath && androidClipboard != nil)) }
    var canMutateFiles: Bool {
        !isBusy && !FileOperationHistory.shared.isBusy && fileTransferProgress == nil && archiveProgress == nil && transferProgress == nil
            && (!isWeChatAttachmentsView || (!weChatCleanup.isScanning && !weChatCleanup.isCleaning))
            && (activeStorageCleanup?.busy != true)
    }
    var deleteActionTitle: String { isAndroidPath ? L("android.deletePermanent", "永久删除…") : L("action.moveToTrash", "移到废纸篓") }
    var confirmAndroidDeletion: (([AndroidEntry]) -> Bool)?
    @Published var statusMessage: String = ""
    @Published var folderPickerRequest: FolderPickerRequest?
    @Published var errorMessage: String?
    @Published private(set) var directoryReadError: String?
    @Published var isBusy = false
    @Published var categoryFilter: FileCategory?

    let engine: FSEngine
    private var cleanupBacking: WeChatCleanupModel?
    private var storageBacking: StorageCleanupModel?
    private var softwareBacking: StorageCleanupModel?
    var initializedCleanupCount: Int { [cleanupBacking != nil, storageBacking != nil, softwareBacking != nil].filter { $0 }.count }
    var cleanupIsCleaning: Bool { cleanupBacking?.isCleaning == true || storageBacking?.isCleaning == true || softwareBacking?.isCleaning == true }
    var weChatCleanup: WeChatCleanupModel {
        if let cleanupBacking { return cleanupBacking }
        let value = WeChatCleanupModel()
        cleanupBacking = value
        cleanupSubscription = value.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return value
    }
    var storageCleanup: StorageCleanupModel {
        if let storageBacking { return storageBacking }
        let value = StorageCleanupModel()
        storageBacking = value
        storageCleanupSubscription = value.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return value
    }
    var softwareCleanup: StorageCleanupModel {
        if let softwareBacking { return softwareBacking }
        let value = StorageCleanupModel(softwareMode: true)
        softwareBacking = value
        softwareCleanupSubscription = value.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return value
    }
    private var softwareCleanupSubscription: AnyCancellable?
    private var storageCleanupSubscription: AnyCancellable?
    private var backStack: [SidebarSelection] = []
    private var forwardStack: [SidebarSelection] = []
    private var listingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var categoryTask: Task<Void, Never>?
    private var homeTask: Task<Void, Never>?
    private var navigationID = UUID()
    private var languageSubscription: AnyCancellable?
    private var cleanupSubscription: AnyCancellable?
    private var clipboardSubscription: AnyCancellable?

    init(engine: FSEngine, startDirectory: URL?, cleanupModel: WeChatCleanupModel? = nil, storageCleanupModel: StorageCleanupModel? = nil, softwareCleanupModel: StorageCleanupModel? = nil, clipboardStore: FileClipboard? = nil, androidRegistry: AndroidDeviceRegistry? = nil, androidOpenService: AndroidOpenService? = nil, androidOpenHandler: (([URL], Bool) -> Void)? = nil, androidVideoHandler: ((AndroidEntry, Bool, ScanCancellation) async throws -> Void)? = nil) {
        self.engine = engine
        self.androidRegistry = androidRegistry ?? .shared
        self.androidOpenService = androidOpenService ?? .shared
        self.androidOpenHandler = androidOpenHandler
        self.androidVideoHandler = androidVideoHandler
        self.clipboardStore = clipboardStore ?? .shared
        self.cleanupBacking = cleanupModel
        self.storageBacking = storageCleanupModel
        self.softwareBacking = softwareCleanupModel
        androidDevicesSubscription = self.androidRegistry.$devices.dropFirst().sink { [weak self] devices in
            self?.androidConnectionsChanged(devices)
        }
        filesChangedSubscription = NotificationCenter.default.publisher(for: .winFileFilesChanged)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, !self.isSuspended, !self.isBusy, self.showsFileList || self.isCleanupView else { return }
                self.reload()
            }
        clipboardSubscription = self.clipboardStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        softwareCleanupSubscription = softwareCleanupModel?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        storageCleanupSubscription = storageCleanupModel?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        cleanupSubscription = cleanupModel?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        languageSubscription = Localization.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLocalizedContent() }
        if let start = startDirectory {
            currentDirectory = start
            selection = .folder(start)
            reload()
        }
    }

    deinit {
        transferCancellation?.cancel()
        transferTask?.cancel()
        androidOpenCancellation?.cancel()
        androidOpenTask?.cancel()
        archiveCancellation?.cancel()
        searchCancellation?.cancel()
        categoryCancellation?.cancel()
        fileTransferCancellation?.cancel()
        pathTask?.cancel()
        directoryRefreshTask?.cancel()
        listingTask?.cancel()
        searchTask?.cancel()
        categoryTask?.cancel()
        homeTask?.cancel()
    }

    private func refreshLocalizedContent() {
        quickAccess = PlacesService.quickAccessFolders()
        if isHomeView {
            statusMessage = recentEntries.isEmpty ? L("status.homeEmpty", "最近没有修改或打开过文件")
                : L("status.homeCount", "最近使用 %d 项", recentEntries.count)
        } else if isAppDataView {
            statusMessage = L("status.appDataCount", "共 %d 个应用数据目录（%d 个可浏览）", appDataItems.count, appDataItems.filter(\.isReadable).count)
        } else if showsFileList && !isBusy {
            updateStatus()
        } else {
            statusMessage = ""
        }
        objectWillChange.send()
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

    var isStorageCleanupView: Bool { selection == .storageCleanup }

    // Keep the destination case for existing saved sessions and navigation history.
    var isWeChatCleanupView: Bool { selection == .weChatCleanup }
    var isCleanupView: Bool { isStorageCleanupView || isWeChatCleanupView }
    var cleanupSection: CleanupSection { isWeChatCleanupView ? .software : .general }
    var sidebarSelection: SidebarSelection? { isCleanupView ? .storageCleanup : selection }
    var isCleaningStorage: Bool { cleanupIsCleaning }
    func selectSidebarDestination(_ destination: SidebarSelection) {
        if destination == .storageCleanup && isCleanupView { return }
        navigate(to: destination)
    }
    @discardableResult
    func selectCleanupSection(_ section: CleanupSection) -> Bool {
        guard !isCleaningStorage else { return false }
        guard !isCleanupView || section != cleanupSection else { return true }
        storageCleanup.cancel(); softwareCleanup.cancel(); weChatCleanup.cancelScan()
        storageCleanup.discardPendingTrash(); softwareCleanup.discardPendingTrash(); weChatCleanup.discardPendingTrash()
        navigate(to: section == .general ? .storageCleanup : .weChatCleanup)
        return true
    }
    var isWeChatAttachmentsView: Bool { isWeChatCleanupView && softwareCleanup.selectedSoftwareID == "wechat" }
    var activeStorageCleanup: StorageCleanupModel? {
        isStorageCleanupView ? storageCleanup : (isWeChatCleanupView && !isWeChatAttachmentsView ? softwareCleanup : nil)
    }
    func selectCleanupSoftware(_ id: String) {
        guard !weChatCleanup.isCleaning, !softwareCleanup.isCleaning else { return }
        guard id != softwareCleanup.selectedSoftwareID else { return }
        guard softwareCleanup.selectSoftware(id) else { return }
        weChatCleanup.cancelScan(); weChatCleanup.discardPendingTrash()
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
            && !isAndroidDeviceView && !isApplicationsView && !isWeChatCleanupView && !isStorageCleanupView
    }

    var supportsDirectorySearch: Bool {
        showsFileList && currentDirectory != nil && !isCategoryView && !isAndroidPath
    }

    var supportsDirectoryCreation: Bool {
        showsFileList && currentDirectory != nil && !isCategoryView
    }

    /// 当前是否为安卓路径（安卓目录浏览由 MTP 提供，与本地文件区分处理）
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
        if let store = activeStorageCleanup { return store.selectedFiles.compactMap { FileItem(url: $0.url, resourceKeys: FileSystemService.resourceKeys, showHidden: true) } }
        if isWeChatCleanupView { return weChatCleanup.selectedFiles.map { FileItem(weChatFile: $0) } }
        return displayedItems.filter { selectedIDs.contains($0.id) }
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
        case .storageCleanup: return L("cleanup.title", "空间清理")
        case .weChatCleanup:
            return L("cleanup.title", "空间清理")
        case .androidDevice(let serial):
            return AndroidDeviceRegistry.shared.device(serial: serial)?.displayName
                ?? L("view.androidDevice", "安卓设备")
        case .category(let category):
            return category.localizedName
        case .folder(let url):
            if let (serial, path) = AndroidURL.split(url) {
                if path == "/" { return androidRegistry.device(serial: serial)?.displayName ?? L("view.androidDevice", "安卓设备") }
                if let root = androidRegistry.roots(for: serial).first(where: { $0.path == path }) { return root.label }
                return url.lastPathComponent
            }
            // 根目录的 lastPathComponent 为空，直接显示磁盘名
            return url.path == "/"
                ? WLocalizedString("place.macintoshHD", comment: "启动磁盘")
                : url.lastPathComponent
        case nil:
            return ""
        }
    }

    // MARK: - 导航

    private func beginPageLoad() {
        isSuspended = false
        directoryReadError = nil
        navigationID = UUID()
        listingTask?.cancel(); homeTask?.cancel()
        isLoadingHome = false; isLoadingDrives = false; isLoadingAppData = false; isLoadingAndroid = false
    }

    func navigate(to target: SidebarSelection, recordHistory: Bool = true) {
        isSuspended = false
        if recordHistory, let current = selection, current != target {
            backStack.append(current)
            forwardStack.removeAll()
        }
        TabDiagnostics.shared.record("navigate", detail: "目标=\(describe(target)) 旧=\(describe(selection))")
        navigationID = UUID()
        listingTask?.cancel()
        homeTask?.cancel()
        isLoadingHome = false; isLoadingDrives = false; isLoadingAppData = false; isLoadingAndroid = false
        isLoadingCategory = false
        directoryWatcher = nil
        watchedDirectory = nil
        directoryRefreshTask?.cancel()
        searchCancellation?.cancel()
        searchTask?.cancel()
        categoryCancellation?.cancel()
        categoryTask?.cancel()
        searchID = UUID()
        categoryID = UUID()
        scanReport = FileScanReport()
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
        case .weChatCleanup, .storageCleanup:
            loadCleanupPage()
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
        case .weChatCleanup: return "软件清理"
        case .storageCleanup: return "空间清理"
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
        if let store = activeStorageCleanup { store.scan(); return }
        if isWeChatCleanupView { weChatCleanup.scan(); return }
        if let category = categoryFilter { loadCategory(category, expanding: true); return }
        if isSearching { search(searchQuery, expanding: true); return }
        if isHomeView { loadHome(); return }
        if isThisPCView { loadThisPC(); return }
        if isAppDataView { loadAppData(); return }
        if case .androidDevice(let serial) = selection { loadAndroidDevice(serial: serial); return }
        guard let dir = currentDirectory else {
            if case .applications = selection { loadApplications() }
            return
        }
        load(directory: dir, resetCategory: false)
    }

    var canExpandScan: Bool { (isSearching || isCategoryView) && scanReport.isPartial && !isBusy }
    func expandScan() {
        scanEntryLimit = min(scanEntryLimit * 2, 2_000_000)
        if let category = categoryFilter {
            categoryLimit += 800
            categoryDepth += 4
            loadCategory(category, expanding: true)
        } else if isSearching {
            searchLimit += 800
            search(searchQuery, expanding: true)
        }
    }
    func cancelScan() {
        if isSearching { clearSearch() }
        else if isLoadingCategory {
            categoryCancellation?.cancel()
            categoryTask?.cancel()
            categoryID = UUID()
            isLoadingCategory = false
            isBusy = false
        }
    }

    var scanCompletenessMessage: String? {
        guard isSearching || isCategoryView, scanReport.isPartial else { return nil }
        var parts: [String] = []
        if scanReport.limitReached { parts.append(L("scan.resultLimit", "已达到当前显示数量，可继续加载")) }
        if scanReport.depthLimited { parts.append(L("scan.depthLimit", "还有更深层目录未扫描")) }
        if scanReport.visitLimitReached { parts.append(L("scan.visitLimit", "已达到本次遍历上限")) }
        if scanReport.inaccessibleCount > 0 { parts.append(L("scan.unreadable", "%d 个位置无法读取", scanReport.inaccessibleCount)) }
        return parts.joined(separator: "；")
    }

    private func load(directory: URL, resetCategory: Bool = true) {
        directoryReadError = nil
        beginPageLoad()
        // 安卓路径走 MTP 列目录（本地 FileManager 无法访问设备文件）
        if AndroidURL.isAndroid(directory) {
            loadAndroidDirectory(directory)
            return
        }
        homeTask?.cancel()
        listingTask?.cancel()
        searchTask?.cancel()
        searchCancellation?.cancel()
        categoryTask?.cancel()
        categoryCancellation?.cancel()
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
        let navigation = navigationID
        listingTask = Task { [weak self] in
            var loaded: [FileItem] = []
            var browsingDirectory: URL?
            var failure: NSError?
            do {
                let listing = try await Task.detached(priority: .userInitiated) {
                    try FileSystemService.directoryListing(directory, showHidden: showHidden)
                }.value
                loaded = listing.items
                browsingDirectory = listing.directory
            } catch {
                failure = error as NSError
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.navigationID == navigation else { return }
                self.items = FileSystemService.sort(loaded, field: self.sortField, ascending: self.sortAscending)
                if let pendingID = self.pendingSelectionID,
                   loaded.contains(where: { $0.id == pendingID }) {
                    self.selectedIDs = [pendingID]
                } else {
                    self.selectedIDs = self.selectedIDs.filter { id in loaded.contains { $0.id == id } }
                    self.pendingSelectionID = nil
                }
                self.isBusy = false
                if let failure {
                    self.directoryWatcher = nil
                    self.watchedDirectory = nil
                    TabDiagnostics.shared.recordFileError(failure, operation: "listDirectory", url: directory)
                    self.directoryReadError = failure.localizedDescription
                    self.errorMessage = failure.localizedDescription
                    self.statusMessage = failure.localizedDescription
                } else {
                    if let browsingDirectory {
                        self.currentDirectory = browsingDirectory
                        if case .folder = self.selection { self.selection = .folder(browsingDirectory) }
                    }
                    self.errorMessage = nil
                    self.updateStatus()
                    self.installDirectoryWatcher()
                }
            }
        }
    }

    /// Resolve typed paths off the main thread. Invalid paths never navigate to an unrelated parent.
    private var pathTask: Task<Void, Never>?
    func openPath(_ text: String) {
        pathTask?.cancel()
        let base = currentDirectory?.isFileURL == true ? currentDirectory! : FileSystemService.realHomeDirectory()
        let navigation = navigationID
        pathTask = Task { [weak self] in
            do {
                let target = try await Task.detached(priority: .userInitiated) { () throws -> (URL, Bool) in
                    guard let url = FolderPickerModel.resolvePath(text, relativeTo: base) else { throw FSError.notFound(base) }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                    return (url, values.isDirectory == true || FSEngine.isSidebarFolder(url))
                }.value
                guard !Task.isCancelled, let self, self.navigationID == navigation else { return }
                if target.1 { self.selectFolder(target.0) }
                else {
                    self.selectFolder(target.0.deletingLastPathComponent())
                    self.pendingSelectionID = target.0.path
                }
            } catch {
                guard !Task.isCancelled, let self, self.navigationID == navigation else { return }
                TabDiagnostics.shared.recordFileError(error as NSError, operation: "openPath", url: base)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @Published private(set) var isSuspended = false
    func stopWatchingDirectory() {
        watchesChanges = false
        directoryWatcher = nil; watchedDirectory = nil
        directoryRefreshTask?.cancel()
    }
    /// Release only reproducible browser results. Cleanup selections, pending trash,
    /// transfers, navigation history, filters and clipboard state remain intact.
    @discardableResult
    func reclaimReadOnlyResults() -> Bool {
        guard !isSuspended, !isBusy, !isCleanupView, !isAndroidPath,
              archiveProgress == nil, fileTransferProgress == nil, transferProgress == nil,
              !cleanupIsCleaning, showsFileList, currentDirectory?.isFileURL == true || isCategoryView,
              !items.isEmpty || !searchResults.isEmpty || !categoryResults.isEmpty else { return false }
        stopWatchingDirectory()
        isSuspended = true
        items = []; searchResults = []; categoryResults = []
        return true
    }
    func resumeReadOnlyResults() {
        guard isSuspended else { beginWatchingDirectory(); return }
        isSuspended = false
        reload()
        beginWatchingDirectory()
    }

    func beginWatchingDirectory() {
        guard tabManager == nil || tabManager?.activeModel === self else { return }
        watchesChanges = true
        installDirectoryWatcher()
    }
    private func installDirectoryWatcher() {
        guard watchesChanges, let directory = currentDirectory, directory.isFileURL, !isCategoryView else { return }
        guard watchedDirectory?.path != directory.path else { return }
        watchedDirectory = directory
        directoryWatcher = DirectoryWatcher(directory: directory) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleDirectoryRefresh(directory) }
        }
    }
    private func scheduleDirectoryRefresh(_ directory: URL) {
        directoryRefreshTask?.cancel()
        directoryRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.currentDirectory?.path == directory.path,
                  !self.isBusy, self.archiveProgress == nil, self.fileTransferProgress == nil else { return }
            // Read on the listing worker; a disconnected volume remains visible with Retry.
            self.reload()
        }
    }

    // MARK: - 主页（Home）

    func loadHome() {
        beginPageLoad()
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
        let navigation = navigationID
        homeTask = Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                PlacesService.recentEntries(under: roots, limit: 40)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.navigationID == navigation else { return }
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

    /// Table 提供的菜单目标优先于旧选中项；图标右键未选中的项目只操作该项目。
    func sidebarContextItems(item: FileItem?, ids: Set<String>? = nil) -> [FileItem] {
        if let ids { return displayedItems.filter { ids.contains($0.id) } }
        guard let item else { return [] }
        return selectedIDs.contains(item.id) ? selectedItems : [item]
    }

    var currentSidebarFolder: URL? {
        guard showsFileList, !isAggregatedView, let directory = currentDirectory,
              FSEngine.isSidebarFolder(directory) else { return nil }
        return directory
    }

    /// 添加快捷入口不触发导航，也不改变当前选中项或主页收藏。
    @discardableResult
    func addFoldersToSidebar(_ urls: [URL], unresolvedCount: Int = 0) -> SidebarFolderAddition {
        var result = engine.addFolders(urls)
        result.rejectedCount += unresolvedCount
        statusMessage = result.statusMessage
        return result
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

    private func loadCleanupPage() {
        listingTask?.cancel()
        searchTask?.cancel()
        categoryTask?.cancel()
        homeTask?.cancel()
        categoryFilter = nil
        categoryResults = []
        isLoadingCategory = false
        isSearching = false
        searchResults = []
        currentDirectory = nil
        items = []
        fileSelectedIDs = []
        isBusy = false
        statusMessage = ""
    }

    /// 载入「应用数据」列表。
    ///
    /// 说明：读取其它应用的容器需要「完整磁盘访问权限」，
    /// 该权限只能由用户在系统设置中手动授予。未授权时相关目录不可读，
    /// 这里会置起 needsFullDiskAccess 以便界面给出明确指引。
    func loadAppData() {
        beginPageLoad()
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

        let navigation = navigationID
        homeTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                AppDataService.scan()
            }.value
            let sufficient = await Task.detached(priority: .userInitiated) {
                AppDataService.hasSufficientAccess(scanned)
            }.value
            guard let self, !Task.isCancelled, self.navigationID == navigation else { return }
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

    /// 载入安卓目录（经 MTP 列目录）
    func loadAndroidDirectory(_ url: URL) {
        beginPageLoad()
        guard let (serial, path) = AndroidURL.split(url) else {
            errorMessage = L("android.error.badURL", "无法解析设备路径：%@", url.absoluteString)
            return
        }
        homeTask?.cancel()
        androidConnectionIdentity = androidRegistry.device(serial: serial).flatMap { $0.isReady ? $0.serial + "|" + $0.transportID : nil }
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

        let navigation = navigationID
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
            guard let self, !Task.isCancelled, self.navigationID == navigation else { return }
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
                TabDiagnostics.shared.recordFileError(error, operation: "MTP.list", url: url)
                self.errorMessage = error.localizedDescription
                self.directoryReadError = error.localizedDescription
                self.statusMessage = L("status.androidFailed", "读取失败")
            }
        }
    }

    // MARK: - 跳转到文件所在目录

    /// 当前视图是否为「跨目录聚合」：分类与搜索结果来自多个目录，
    /// 因此需要「打开所在文件夹」才能回到文件的真实位置。
    var isAggregatedView: Bool { isCategoryView || isSearching || isWeChatCleanupView }

    /// 跳到指定文件所在的文件夹，并把它选中。
    ///
    /// 用途：分类视图与搜索结果里的文件不在当前目录下，
    /// 用户需要一键回到它的真实位置（Windows 的「打开文件位置」）。
    func openContainingFolder(of item: FileItem) {
        openContainingFolder(of: item.url)
    }

    /// Opens a foreground tab while preserving this page's filters and selection.
    /// Standalone models can also be used to perform the destination navigation.
    func openContainingFolder(of url: URL, inNewTab: Bool = true) {
        if AndroidURL.isAndroid(url) {
            errorMessage = L("android.hint.revealUnsupported",
                             "设备上的文件无法在访达中显示。如需在本机处理，请先复制到本地文件夹。")
            return
        }
        guard url.isFileURL else {
            errorMessage = L("error.notAccessible", "无法访问该位置")
            return
        }
        if inNewTab, let tabManager {
            let tab = tabManager.newTab(startDirectory: url.deletingLastPathComponent())
            tab.model.pendingSelectionID = FileItem.canonicalID(for: url)
            return
        }
        let directory = url.deletingLastPathComponent()
        pendingSelectionID = FileItem.canonicalID(for: url)
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
        guard AndroidURL.split(currentDirectory ?? entries[0].url) != nil else { return }
        let confirmed: Bool
        if let confirmAndroidDeletion { confirmed = confirmAndroidDeletion(entries) }
        else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("android.deleteTitle", "永久删除设备上的 %d 项？", entries.count)
            alert.informativeText = L("android.deleteMessage", "这些项目会从安卓设备永久删除，不会移到废纸篓，无法通过 WinFile 撤销。")
            alert.addButton(withTitle: L("android.deleteConfirm", "永久删除"))
            alert.addButton(withTitle: L("button.cancel", "取消"))
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else { return }
        runAndroidOperation(L("status.deleting", "正在删除…")) { service in
            for entry in entries { try service.remove(entry.path) }
        }
    }

    /// 安卓端重命名
    func renameAndroid(_ entry: AndroidEntry, to newName: String) {
        guard AndroidURL.split(entry.url) != nil else { return }
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

    var canExtract: Bool { canMutateFiles && !selectedArchives.isEmpty && !isAndroidPath }

    var canCompress: Bool { canMutateFiles && !selectedItems.isEmpty && !isAndroidPath && (currentDirectory != nil || isWeChatCleanupView) }

    /// Aggregated cleanup results can span folders; ask where to save a combined archive.
    private func archiveDestination() -> URL? {
        if let currentDirectory { return currentDirectory }
        guard isWeChatCleanupView else { return nil }
        let parents = Set(selectedItems.map { $0.url.deletingLastPathComponent() })
        if parents.count == 1 { return parents.first }
        folderPickerRequest = FolderPickerRequest(title: L("wechat.archiveDestination", "选择压缩文件的保存位置"), initialDirectory: parents.first) { [weak self] url in
            self?.compressSelection(to: url)
        }
        return nil
    }

    /// 压缩选中项到当前目录
    func compressSelection(to requestedDirectory: URL? = nil) {
        guard canCompress, let directory = requestedDirectory ?? archiveDestination() else { return }
        let urls = selectedItems.map(\.url)
        let name = ArchiveService.defaultArchiveName(for: urls)
        archiveProgress = ArchiveProgress(name: name, isCompressing: true)
        Task { [weak self] in
            var failure: String?
            do {
                let target = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.compress(urls, to: directory, name: name)
                }.value
                await MainActor.run { [weak self] in
                    self?.statusMessage = L("status.compressed", "已压缩为 %@", target.lastPathComponent)
                }
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

    /// Process every selected archive; a volume set is extracted only once.
    func extractSelection(to chosenDirectory: URL? = nil, createFolder: Bool = false) {
        guard canExtract else { return }
        let archives = selectedArchives.map(\.url)
        let currentDestination = chosenDirectory ?? currentDirectory
        let token = ScanCancellation()
        archiveCancellation = token
        archiveID = UUID()
        let operationID = archiveID
        lastTransferOutcome = nil
        archiveProgress = ArchiveProgress(name: archives[0].lastPathComponent, isCompressing: false, total: archives.count)
        Task { [weak self] in
            var outcome = FileTransferOutcome()
            var processed = Set<String>()
            for (index, selected) in archives.enumerated() {
                if token.isCancelled { break }
                let archive: URL
                do { archive = try ArchiveService.firstVolume(for: selected) }
                catch { outcome.failures.append("\(selected.lastPathComponent): \(error.localizedDescription)"); continue }
                guard processed.insert(FileItem.canonicalID(for: archive)).inserted else { continue }
                let destination = currentDestination ?? archive.deletingLastPathComponent()
                var password: String?
                var retry = false
                while !token.isCancelled {
                    do {
                        let attemptPassword = password
                        let created = try await Task.detached(priority: .userInitiated) {
                            try ArchiveService.extract(archive, to: destination, password: attemptPassword,
                                createFolder: createFolder, cancellation: token) { fraction in
                                Task { @MainActor [weak self] in
                                    guard let self, self.archiveID == operationID, self.archiveProgress != nil, !token.isCancelled else { return }
                                    self.archiveProgress = ArchiveProgress(name: archive.lastPathComponent, isCompressing: false,
                                        fraction: fraction, index: index + 1, total: archives.count)
                                }
                            }
                        }.value
                        outcome.completed.append(contentsOf: created)
                        break
                    } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
                        guard !token.isCancelled,
                              let entered = self?.askArchivePassword(for: archive, retry: retry) else { token.cancel(); break }
                        password = entered
                        retry = true
                    } catch ArchiveError.cancelled {
                        token.cancel(); break
                    } catch {
                        outcome.failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                        break
                    }
                }
                password = nil
            }
            outcome.cancelled = token.isCancelled
            guard let self, self.archiveID == operationID else { return }
            self.archiveProgress = nil
            self.archiveCancellation = nil
            self.lastTransferOutcome = outcome
            self.reload()
        }
    }

    func chooseExtractionDestination() {
        guard canExtract else { return }
        folderPickerRequest = FolderPickerRequest(title: L("archive.chooseDestination", "选择解压文件的保存位置"), initialDirectory: currentDirectory) { [weak self] directory in
            self?.extractSelection(to: directory)
        }
    }

    func cancelArchiveExtraction() { archiveCancellation?.cancel() }

    private func askArchivePassword(for archive: URL, retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = L("archive.password.title", "输入解压密码")
        alert.informativeText = (retry ? L("archive.error.wrongPassword", "密码错误或加密数据损坏，请检查后重试。") + "\n" : "") + archive.lastPathComponent
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = L("archive.password.placeholder", "密码（仅用于本次解压）")
        alert.accessoryView = field
        alert.addButton(withTitle: L("action.extract", "解压"))
        alert.addButton(withTitle: L("button.cancel", "取消"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// 把选中的安卓条目下载到本机（弹出目录选择）
    func downloadSelectedToLocalFolder() {
        let entries = selectedAndroidEntries
        guard !entries.isEmpty else { return }
        folderPickerRequest = FolderPickerRequest(
            title: L("android.chooseSaveFolder", "下载到此文件夹"),
            initialDirectory: FileSystemService.realHomeDirectory().appendingPathComponent("Downloads")
        ) { [weak self] target in
            guard let self else { return }
            self.downloadFromAndroid(entries, to: target)
        }
    }

    /// 把剪贴板内容粘贴到当前安卓目录
    ///
    /// - 剪贴板是本机文件 → 上传
    /// - 剪贴板是安卓文件 → 设备内复制/移动
    func pasteIntoAndroid() {
        guard let directory = currentDirectory,
            let (serial, remotePath) = AndroidURL.split(directory)
        else { return }

        // 情况一：本机文件 → 上传
        let localURLs = (clipboard?.urls ?? []).filter { !AndroidURL.isAndroid($0) }
        if !localURLs.isEmpty {
            uploadToAndroid(localURLs, to: directory)
            return
        }

        // 情况二：安卓文件 → 设备内复制/移动
        guard let payload = androidClipboard else { return }
        guard payload.entry.serial == serial else {
            errorMessage = L("android.crossDevicePaste", "跨设备粘贴请先下载到本机，再上传到目标设备。")
            return
        }
        let clipboardGeneration = clipboardStore.changeCount
        let move = payload.isCut
        transferProgress = AndroidTransferProgress(
            name: payload.entry.name,
            direction: .upload)
        let token = ScanCancellation()
        transferCancellation = token
        transferSerial = serial
        transferTask = Task { [weak self] in
            let error: Error? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let service = AndroidFileService(serial: serial)
                    do {
                        if move {
                            try service.move(payload.entry.path, to: remotePath)
                        } else {
                            try service.copy(payload.entry.path, to: remotePath, cancellation: token)
                        }
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error)
                    }
                }
            }
            guard let self else { return }
            self.transferProgress = nil
            self.transferCancellation = nil
            self.transferSerial = nil
            if let error {
                if !token.isCancelled { self.errorMessage = error.localizedDescription }
                self.statusMessage = L("status.pasteFailed", "粘贴失败")
            } else {
                self.statusMessage =
                    move
                    ? L("status.moved", "已移动")
                    : L("status.copied", "已复制")
                if move { self.clipboardStore.clear(ifGeneration: clipboardGeneration) }
                if let dir = self.currentDirectory { self.loadAndroidDirectory(dir) }
            }
        }
    }

    /// 在后台执行一次安卓操作，完成后刷新目录
    private func runAndroidOperation(
        _ title: String,
        _ body: @escaping (AndroidFileService) throws -> Void
    ) {
        guard let directory = currentDirectory,
            let (serial, _) = AndroidURL.split(directory)
        else { return }
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
    var androidClipboard: AndroidClipboardPayload? { clipboardStore.androidPayload }

    /// 当前选中的安卓条目
    var selectedAndroidEntries: [AndroidEntry] {
        let paths = Set(selectedItems.map { $0.url.path })
        return androidEntries.filter { paths.contains($0.path) }
    }

    private func androidConnectionsChanged(_ devices: [AndroidDevice]) {
        // An initially busy USB device has no MTP serial yet. Upgrade only its
        // empty device page; never redirect another phone's directory or transfer.
        if case .androidDevice(let serial) = selection,
           let previous = androidRegistry.device(serial: serial), previous.hasTemporaryIdentity,
           let resolved = devices.first(where: { $0.transportID == previous.transportID && $0.isReady }),
           resolved.serial != serial {
            TabDiagnostics.shared.record("mtp.page.identityResolved", detail: resolved.diagnosticSummary)
            loadAndroidDevice(serial: resolved.serial)
        }
        if case .androidDevice(let serial) = selection {
            statusMessage = Self.androidDeviceStatus(devices.first { $0.serial == serial })
        }
        if let serial = transferSerial, !devices.contains(where: { $0.serial == serial && $0.isReady }) {
            transferCancellation?.cancel()
        }
        if let serial = androidOpenSerial, !devices.contains(where: { $0.serial == serial && $0.isReady }) {
            cancelAndroidOpen()
        }
        guard let directory = currentDirectory, let (serial, _) = AndroidURL.split(directory) else { return }
        let device = devices.first { $0.serial == serial }
        let identity = device.flatMap { $0.isReady ? $0.serial + "|" + $0.transportID : nil }
        if let identity {
            if androidConnectionIdentity != identity {
                loadAndroidDirectory(directory)
                androidConnectionIdentity = identity
            }
        } else if androidConnectionIdentity != nil || directoryReadError == nil {
            androidConnectionIdentity = nil
            homeTask?.cancel()
            navigationID = UUID()
            androidEntries = []
            items = []
            selectedIDs = []
            isLoadingAndroid = false
            isBusy = false
            let message = Self.androidConnectionMessage(device)
            directoryReadError = message
            errorMessage = nil
            statusMessage = message
        }
    }

    static func androidDeviceStatus(_ device: AndroidDevice?) -> String {
        device?.isReady == true
            ? L("android.connection.ready", "设备已连接，请选择存储位置。")
            : androidConnectionMessage(device)
    }

    static func androidConnectionMessage(_ device: AndroidDevice?) -> String {
        if device?.state == "unavailable" {
            return L("android.connection.busy", "无法建立 MTP 会话。设备可能被「预览」「照片」「图像捕捉」或其他传输软件占用；请完全退出占用的应用，仅关闭窗口可能不会释放设备。若刚切换 USB 模式，请稍候，WinFile 会自动重试。")
        }
        if device?.needsFileTransfer == true {
            return L("android.connection.notReady", "请解锁安卓设备，选择 USB「文件传输」，并关闭其他占用设备的传输软件；就绪后将自动恢复。")
        }
        return L("android.connection.disconnected", "安卓设备已断开。重新连接并选择「文件传输」后，将自动恢复此目录。")
    }

    func activateAndroid(_ entry: AndroidEntry) {
        if entry.isDirectory { selectFolder(entry.url) } else { openAndroidFiles([entry]) }
    }

    /// Videos use MTP/RAM playback; external document applications need verified local copies.
    func openAndroidFiles(_ entries: [AndroidEntry], preview: Bool = false) {
        guard transferProgress == nil else { return }
        let files = entries.filter { !$0.isDirectory }
        guard let first = files.first, files.allSatisfy(AndroidOpenService.valid) else {
            errorMessage = AndroidOpenError.invalidFile.localizedDescription
            return
        }
        let streaming = files.contains(where: AndroidVideoPlayer.handles)
        if streaming && files.count != 1 {
            errorMessage = L("android.stream.single", "请选择一个视频进行流式播放。批量保存请使用「下载」。")
            return
        }
        let id = UUID(), token = ScanCancellation(), service = androidOpenService
        androidOpenID = id
        androidOpenCancellation = token
        androidOpenSerial = first.serial
        isOpeningAndroidFile = true
        transferProgress = AndroidTransferProgress(name: first.name, direction: streaming ? .stream : .open)
        errorMessage = nil
        androidOpenTask = Task { [weak self] in
            defer {
                if let self, self.androidOpenID == id {
                    self.transferProgress = nil
                    self.isOpeningAndroidFile = false
                    self.androidOpenCancellation = nil
                    self.androidOpenSerial = nil
                    self.androidOpenTask = nil
                }
            }
            var urls: [URL] = []
            do {
                if streaming {
                    if let handler = self?.androidVideoHandler { try await handler(first, preview, token) }
                    else { try await AndroidVideoPlayer.shared.open(first, preview: preview, cancellation: token) }
                    guard let self, self.androidOpenID == id, !token.isCancelled else { throw CancellationError() }
                    self.statusMessage = L("android.stream.opened", "视频已通过 MTP 在内存中打开，未创建完整本机副本。")
                    return
                }
                for entry in files {
                    if token.isCancelled { throw CancellationError() }
                    self?.transferProgress = AndroidTransferProgress(name: entry.name, direction: .open)
                    let url = try await Task.detached(priority: .userInitiated) {
                        try service.prepare(entry, cancellation: token) { fraction in
                            Task { @MainActor [weak self] in
                                guard let self, self.androidOpenID == id, !token.isCancelled,
                                    self.transferProgress?.name == entry.name
                                else { return }
                                if let fraction {
                                    self.transferProgress?.fraction = max(
                                        self.transferProgress?.fraction ?? 0, fraction)
                                }
                            }
                        }
                    }.value
                    urls.append(url)
                }
                guard let self, self.androidOpenID == id, !token.isCancelled, !Task.isCancelled else {
                    throw CancellationError()
                }
                // Closing Preview.app's document window leaves its camera browser alive.
                // Route Android pictures/PDFs to our Quick Look panel to avoid claiming USB.
                let inAppURLs = zip(files, urls).filter { preview || AndroidOpenService.prefersInAppPreview($0.0) }.map { $0.1 }
                let externalURLs = zip(files, urls).filter { !preview && !AndroidOpenService.prefersInAppPreview($0.0) }.map { $0.1 }
                TabDiagnostics.shared.record("android.open.route", detail: "inApp=\(inAppURLs.count) external=\(externalURLs.count)")
                if !inAppURLs.isEmpty {
                    if let handler = self.androidOpenHandler { handler(inAppURLs, true) }
                    else { QuickLookService.shared.show(inAppURLs) }
                }
                if let handler = self.androidOpenHandler {
                    if !externalURLs.isEmpty { handler(externalURLs, false) }
                } else {
                    for url in externalURLs {
                        if let application = FileAssociations.shared.application(for: url) {
                            self.open([url], with: application)
                        } else if !NSWorkspace.shared.open(url) {
                            self.errorMessage = L("error.openFailed", "无法打开")
                        }
                    }
                }
                self.statusMessage = L("android.open.complete", "已打开 %d 个本机缓存副本；修改不会回传到安卓设备。", urls.count)
            } catch {
                guard let self, self.androidOpenID == id else { return }
                if token.isCancelled || error is CancellationError {
                    self.statusMessage = streaming ? L("android.stream.cancelled", "已取消流式播放。") : L("android.open.cancelled", "已取消下载并打开。")
                } else {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = streaming ? L("android.stream.stopped", "流式播放未完成，未自动下载视频。") : L("status.downloadFailed", "下载失败")
                }
            }
        }
    }

    func cancelAndroidOpen() {
        androidOpenCancellation?.cancel()
        androidOpenTask?.cancel()
    }

    func cancelAndroidTransfer() {
        if isOpeningAndroidFile { cancelAndroidOpen() } else { transferCancellation?.cancel() }
    }

    /// Download all selected items in order; do not silently skip later items while the first runs.
    func downloadFromAndroid(_ entries: [AndroidEntry], to localDirectory: URL) {
        guard transferProgress == nil, let first = entries.first else { return }
        let token = ScanCancellation()
        transferCancellation = token
        transferSerial = first.serial
        transferProgress = AndroidTransferProgress(name: first.name, direction: .download)
        transferTask = Task { [weak self] in
            var completed = 0
            do {
                for entry in entries {
                    if token.isCancelled { throw CancellationError() }
                    self?.transferProgress = AndroidTransferProgress(name: entry.name, direction: .download)
                    try await Task.detached(priority: .userInitiated) {
                        try AndroidFileService(serial: entry.serial).pull(
                            remote: entry.path, to: localDirectory, cancellation: token
                        ) { fraction in
                            Task { @MainActor [weak self] in
                                if let self, self.transferCancellation === token, !token.isCancelled {
                                    self.transferProgress?.fraction = fraction
                                }
                            }
                        }
                    }.value
                    completed += 1
                }
                self?.statusMessage = L("android.mtp.downloaded", "已下载 %d 项", completed)
            } catch {
                if !token.isCancelled { self?.errorMessage = error.localizedDescription }
                self?.statusMessage = L("android.mtp.finished", "已完成 %d 项；其余项目未完成。", completed)
            }
            self?.transferProgress = nil
            self?.transferCancellation = nil
            self?.transferSerial = nil
        }
    }

    func uploadToAndroid(_ urls: [URL], to androidDirectory: URL) {
        guard transferProgress == nil, let (serial, remotePath) = AndroidURL.split(androidDirectory) else { return }
        let token = ScanCancellation()
        transferCancellation = token
        transferSerial = serial
        transferProgress = AndroidTransferProgress(
            name: urls.map(\.lastPathComponent).joined(separator: "、"), direction: .upload)
        transferTask = Task { [weak self] in
            var completed = 0
            do {
                for url in urls {
                    if token.isCancelled { throw CancellationError() }
                    self?.transferProgress = AndroidTransferProgress(name: url.lastPathComponent, direction: .upload)
                    try await Task.detached(priority: .userInitiated) {
                        try AndroidFileService(serial: serial).push(local: url, to: remotePath, cancellation: token) {
                            fraction in
                            Task { @MainActor [weak self] in
                                if let self, self.transferCancellation === token, !token.isCancelled {
                                    self.transferProgress?.fraction = fraction
                                }
                            }
                        }
                    }.value
                    completed += 1
                }
                self?.statusMessage = L("status.uploaded", "已上传 %d 项", completed)
            } catch {
                if !token.isCancelled { self?.errorMessage = error.localizedDescription }
                self?.statusMessage = L("android.mtp.finished", "已完成 %d 项；其余项目未完成。", completed)
            }
            self?.transferProgress = nil
            self?.transferCancellation = nil
            self?.transferSerial = nil
            if self?.currentDirectory == androidDirectory { self?.loadAndroidDirectory(androidDirectory) }
        }
    }

    func loadAndroidDevice(serial: String) {
        beginPageLoad()
        homeTask?.cancel()
        let destination = SidebarSelection.androidDevice(serial: serial)
        if selection != destination { selection = destination }
        categoryFilter = nil
        categoryResults = []
        isSearching = false
        searchResults = []
        currentDirectory = nil
        items = []
        selectedIDs = []
        isBusy = false
        statusMessage = Self.androidDeviceStatus(androidRegistry.device(serial: serial))
    }

    func loadThisPC() {
        beginPageLoad()
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
        let navigation = navigationID
        homeTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                PlacesService.drives()
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.navigationID == navigation else { return }
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
    func loadCategory(_ category: FileCategory, expanding: Bool = false) {
        categoryTask?.cancel()
        categoryCancellation?.cancel()
        listingTask?.cancel()
        searchCancellation?.cancel()
        searchTask?.cancel()
        if !expanding { categoryLimit = 800; categoryDepth = 4; scanEntryLimit = 100_000 }
        let token = ScanCancellation()
        categoryCancellation = token
        let id = UUID()
        categoryID = id
        let budget = categoryLimit
        let depth = categoryDepth
        let entryLimit = scanEntryLimit
        let oldSelection = selectedIDs
        categoryFilter = category
        isSearching = false
        searchResults = []
        categoryResults = []
        isLoadingCategory = true
        isBusy = true
        statusMessage = L("status.categoryLoading", "正在归类「%@」…", category.localizedName)
        let roots = engine.browsableRoots
        categoryTask = Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                FileSystemService.categoryReport(category, under: roots, depth: depth, budget: budget,
                    entryLimit: entryLimit, cancelled: { token.isCancelled })
            }.value
            let found = report.items
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.categoryID == id, self.categoryFilter == category else { return }
                self.scanReport = report
                self.categoryResults = FileSystemService.sort(found, field: self.sortField, ascending: self.sortAscending)
                self.isLoadingCategory = false
                self.isBusy = false
                self.selectedIDs = oldSelection.intersection(Set(found.map(\.id)))
                if found.isEmpty {
                    self.statusMessage = L("status.categoryEmpty", "%@：没有找到文件", category.localizedName)
                } else {
                    let truncated = report.limitReached
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
        beginPageLoad()
        listingTask?.cancel()
        categoryTask?.cancel()
        currentDirectory = nil
        isSearching = false
        categoryFilter = nil
        categoryResults = []
        isLoadingCategory = false
        isBusy = true
        let navigation = navigationID
        listingTask = Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) {
                FileSystemService.listApplications()
            }.value
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.navigationID == navigation else { return }
                self.items = apps
                self.selectedIDs = []
                self.isBusy = false
                self.statusMessage = String(format: WLocalizedString("status.appCount", comment: "应用数量"), apps.count)
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
        searchResults = FileSystemService.sort(searchResults, field: sortField, ascending: sortAscending)
        categoryResults = FileSystemService.sort(categoryResults, field: sortField, ascending: sortAscending)
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
        if let store = activeStorageCleanup { store.selectAll(); return }
        selectedIDs = isWeChatCleanupView ? Set(weChatCleanup.visibleFiles.map(\.id)) : Set(displayedItems.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    // MARK: - 操作

    func activate(_ original: FileItem) {
        let item = original
        TabDiagnostics.shared.record("activate", detail: "项目=\(item.name) 目录=\(item.isDirectory)")
        // 安卓条目不能交给 NSWorkspace（android:// 不是本机可打开的地址）
        if AndroidURL.isAndroid(item.url) {
            if let entry = androidEntries.first(where: { $0.path == item.url.path }) {
                activateAndroid(entry)
            }
            return
        }
        activateLocal(original)
    }

    private func activateLocal(_ original: FileItem) {
        let item: FileItem
        do { item = try original.resolvedForOpening() }
        catch {
            TabDiagnostics.shared.recordFileError(error, operation: "resolveForOpening", url: original.url)
            errorMessage = error.localizedDescription
            return
        }
        // .app 包双击启动；普通文件夹进入浏览
        if item.isBundle && item.url.pathExtension.lowercased() == "app" {
            noteOpened(item.url)
            if !engine.open(item) { errorMessage = engine.lastError ?? L("error.openFailed", "无法打开") }
            return
        }
        if item.isDirectory {
            selectFolder(item.url)
            return
        }
        // WinFile 内的默认打开方式优先于系统默认。
        // 注意：这只影响本应用，不会改动 macOS 的关联设置。
        if let app = FileAssociations.shared.application(for: item.url) {
            noteOpened(item.url)
            open([item.url], with: app)
            return
        }
        noteOpened(item.url)
        if !engine.open(item) { errorMessage = engine.lastError ?? L("error.openFailed", "无法打开") }
    }

    /// 用指定应用打开若干文件
    func open(_ urls: [URL], with app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.errorMessage = error.localizedDescription }
            }
        }
    }

    /// 为当前选中文件的类型设置 WinFile 内的默认打开方式
    func setDefaultApplication(_ app: URL, for item: FileItem) {
        guard let ext = FileAssociations.key(for: item.url) else {
            errorMessage = L("assoc.error.noExtension", "该文件没有扩展名，无法按类型设置。")
            return
        }
        FileAssociations.shared.setApplication(app, forExtension: ext)
        statusMessage = L("assoc.saved", "已将 .%@ 的默认打开方式设为「%@」（仅在本应用内生效）",
                          ext, app.deletingPathExtension().lastPathComponent)
    }

    /// 清除当前选中文件类型的自定义打开方式（恢复跟随系统）
    func clearDefaultApplication(for item: FileItem) {
        guard let ext = FileAssociations.key(for: item.url) else { return }
        FileAssociations.shared.clear(extension: ext)
        statusMessage = L("assoc.cleared", "已恢复跟随系统打开 .%@", ext)
    }

    func previewSelection() {
        if isAndroidPath {
            openAndroidFiles(selectedAndroidEntries, preview: true)
            return
        }
        QuickLookService.shared.show(selectedItems.map(\.url))
    }

    func openSelection() {
        if isAndroidPath {
            let entries = selectedAndroidEntries
            if entries.count == 1, let entry = entries.first { activateAndroid(entry) }
            else { openAndroidFiles(entries) }
        } else { for item in selectedItems { activate(item) } }
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
                clipboardStore.writeAndroid(AndroidClipboardPayload(entry: entry, isCut: false))
                statusMessage = L("clipboard.copied", "已复制")
            }
            return
        }
        clipboardStore.write(ClipboardPayload(mode: .copy, urls: urls))
        statusMessage = String(format: WLocalizedString("status.copied", comment: "已复制到剪贴板"), urls.count)
    }

    func cutSelectionToClipboard() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        if isAndroidPath {
            if let entry = selectedAndroidEntries.first {
                clipboardStore.writeAndroid(AndroidClipboardPayload(entry: entry, isCut: true))
                statusMessage = L("clipboard.cut", "已剪切")
            }
            return
        }
        clipboardStore.write(ClipboardPayload(mode: .cut, urls: urls))
        statusMessage = String(format: WLocalizedString("status.cut", comment: "已剪切到剪贴板"), urls.count)
    }

    /// 复制选中的文件路径文本到剪贴板
    func copyPathToClipboard(includeDirectory: Bool = false) {
        let urls = selectedItems.map { includeDirectory ? $0.url.deletingLastPathComponent() : $0.url }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        statusMessage = WLocalizedString("status.pathCopied", comment: "路径已复制")
    }

    func copyNameToClipboard() {
        let names = selectedItems.map(\.name)
        guard !names.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
        statusMessage = WLocalizedString("status.nameCopied", comment: "名称已复制")
    }

    func paste() {
        guard canMutateFiles else { return }
        // 目标是安卓目录时走 MTP（上传或设备内复制/移动）
        if isAndroidPath {
            pasteIntoAndroid()
            return
        }
        guard let clipboard, let directory = currentDirectory else { return }
        startFileTransfer(clipboard.urls, to: directory, mode: clipboard.mode == .copy ? .copy : .move,
                          clipboardGeneration: clipboardStore.changeCount)
    }

    func retryFileTransfer() {
        guard let result = lastTransferOutcome, let directory = result.destination, !result.retryURLs.isEmpty else { return }
        startFileTransfer(result.retryURLs, to: directory, mode: result.isMoving ? .move : .copy, clipboardGeneration: result.clipboardGeneration)
    }

    func copyFiles(_ urls: [URL], to directory: URL) {
        guard directory.isFileURL else { return }
        startFileTransfer(urls.filter(\.isFileURL), to: directory, mode: .copy)
    }

    func openTransferResult() {
        guard let directory = lastTransferOutcome?.destination else { return }
        if let manager = tabManager { manager.newTab(startDirectory: directory) }
        else { selectFolder(directory) }
    }

    private func startFileTransfer(_ urls: [URL], to directory: URL, mode: FSEngine.TransferMode, clipboardGeneration: Int? = nil) {
        guard canMutateFiles, !urls.isEmpty else { return }
        let navigation = navigationID
        let token = ScanCancellation()
        fileTransferCancellation = token
        let id = UUID()
        fileTransferID = id
        isBusy = true
        lastTransferOutcome = nil
        fileTransferProgress = FileTransferProgress(total: urls.count, isMoving: mode == .move)
        Task { [weak self] in
            let items = await Self.fileItems(for: urls, cancelled: { token.isCancelled })
            var outcome = await Task.detached(priority: .userInitiated) { [weak self] in
                FileTransferService.transfer(items, to: directory, mode: mode, token: token) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.fileTransferID == id else { return }
                        self.fileTransferProgress = progress
                    }
                }
            }.value
            if !token.isCancelled {
                let existing = Set(items.map { FileItem.canonicalID(for: $0.url) })
                outcome.failures += urls.filter { !existing.contains(FileItem.canonicalID(for: $0)) }
                    .map { L("operation.sourceMissing", "源文件不存在或不可读取：%@", $0.path) }
            }
            guard let self, self.fileTransferID == id else { return }
            outcome.retryURLs += urls.filter { url in !items.contains { $0.id == FileItem.canonicalID(for: url) } }
            outcome.clipboardGeneration = clipboardGeneration
            self.lastTransferOutcome = outcome
            self.fileTransferID = UUID()
            self.fileTransferProgress = nil
            self.fileTransferCancellation = nil
            if self.navigationID == navigation { self.isBusy = false }
            FileOperationHistory.shared.record(title: L("action.moved", "移动"), moves: outcome.moves)
            if mode == .move, !outcome.cancelled, outcome.failures.isEmpty, let clipboardGeneration {
                self.clipboardStore.clear(ifGeneration: clipboardGeneration)
            }
            if self.navigationID == navigation {
                self.statusMessage = L("operation.finished", "已完成 %d 项，失败 %d 项%@", outcome.completed.count,
                    outcome.failures.count, outcome.cancelled ? L("operation.cancelledSuffix", "（已取消）") : "")
                self.reload()
            }
            NotificationCenter.default.post(name: .winFileFilesChanged, object: nil)
        }
    }

    func cancelFileTransfer() { fileTransferCancellation?.cancel() }

    func deleteSelection(permanently: Bool = false) {
        guard canMutateFiles else { return }
        if let store = activeStorageCleanup { store.requestTrash(); return }
        if isWeChatCleanupView {
            guard !isBusy, archiveProgress == nil else { return }
            weChatCleanup.requestTrash()
            return
        }
        let items = selectedItems
        guard !items.isEmpty else { return }
        // 安卓条目走 MTP 删除（本地 FileManager 不适用）
        if isAndroidPath {
            deleteAndroidSelection()
            return
        }
        isBusy = true
        Task { [weak self] in
            var failure: String?
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    if permanently {
                        for item in items { try FileManager.default.removeItem(at: item.url) }
                    } else {
                        try FSEngine.moveToTrash(items)
                    }
                }.value
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if let failure {
                    self.errorMessage = failure
                } else {
                    self.statusMessage = String(format: WLocalizedString("status.deleted", comment: "已删除"), items.count)
                    self.selectedIDs.removeAll()
                }
                self.reload()
            }
        }
    }

    func duplicateSelection() {
        guard canMutateFiles else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        if !isAndroidPath, Set(items.map { $0.url.deletingLastPathComponent() }).count == 1,
           let directory = items.first?.url.deletingLastPathComponent() {
            copyFiles(items.map(\.url), to: directory)
            return
        }
        isBusy = true
        Task { [weak self] in
            var failure: String?
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try FSEngine.duplicate(items)
                }.value
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if let failure { self.errorMessage = failure } else {
                    self.statusMessage = String(format: WLocalizedString("status.duplicated", comment: "已生成副本"), items.count)
                }
                self.reload()
            }
        }
    }

    /// 在后台把 URL 列表解析成 FileItem（逐次 stat，量大时不占主线程）
    private static func fileItems(for urls: [URL], cancelled: @escaping @Sendable () -> Bool = { false }) async -> [FileItem] {
        await Task.detached(priority: .userInitiated) {
            var items: [FileItem] = []
            for url in urls {
                if cancelled() { break }
                if let item = FileItem(url: url, resourceKeys: FileSystemService.resourceKeys, showHidden: true) { items.append(item) }
            }
            return items
        }.value
    }

    func rename(_ item: FileItem, to newName: String) {
        guard canMutateFiles else { return }
        // 安卓条目走 MTP 重命名
        if AndroidURL.isAndroid(item.url),
           let entry = androidEntries.first(where: { $0.path == item.url.path }) {
            renameAndroid(entry, to: newName)
            return
        }
        do {
            let target = try FSEngine.rename(item, to: newName)
            if target.path != item.url.path, let move = FileMoveRecord(original: item.url, current: target) {
                FileOperationHistory.shared.record(title: L("action.rename", "重命名"), moves: [move])
            }
            statusMessage = WLocalizedString("status.renamed", comment: "已重命名")
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
            let url = try FSEngine.createFolder(in: directory, named: name)
            statusMessage = String(format: WLocalizedString("status.created", comment: "已创建"), url.lastPathComponent)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createTextFile(named name: String, contents: String = "") {
        guard let directory = currentDirectory else { return }
        do {
            let url = try FSEngine.createTextFile(in: directory, named: name, contents: contents)
            statusMessage = String(format: WLocalizedString("status.created", comment: "已创建"), url.lastPathComponent)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 把系统剪贴板里的文字保存成文件
    func saveClipboardTextAsFile() -> String? {
        guard let directory = currentDirectory else { return nil }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
        let firstLine = text.split(separator: "\n").first.map(String.init)
            ?? L("clipboard.defaultName", "剪贴板文本")
        let safe = firstLine.replacingOccurrences(of: "/", with: "_").prefix(40)
        do {
            let url = try FSEngine.createTextFile(in: directory, named: "\(safe).txt", contents: text)
            statusMessage = String(format: WLocalizedString("status.created", comment: "已创建"), url.lastPathComponent)
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

    func search(_ text: String, expanding: Bool = false) {
        if let store = activeStorageCleanup { store.search = text; return }
        if isWeChatCleanupView { weChatCleanup.search = text; return }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty || searchCriteria.isActive else { clearSearch(); return }
        guard searchCriteria.isValid else { return }
        guard let root = currentDirectory, !isAndroidPath else { return }
        searchTask?.cancel()
        searchCancellation?.cancel()
        categoryTask?.cancel()
        categoryCancellation?.cancel()
        listingTask?.cancel()
        let oldSelection = selectedIDs
        categoryFilter = nil
        categoryResults = []
        isLoadingCategory = false
        if !expanding { searchLimit = 400; scanEntryLimit = 100_000 }
        let limit = searchLimit
        let entryLimit = scanEntryLimit
        let hidden = showHidden
        let criteria = searchCriteria
        let token = ScanCancellation()
        searchCancellation = token
        let id = UUID()
        searchID = id
        searchQuery = needle
        isSearching = true
        isBusy = true
        searchTask = Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                FileSystemService.searchReport(under: root, matching: needle, limit: limit,
                    entryLimit: entryLimit, showHidden: hidden, criteria: criteria, cancelled: { token.isCancelled })
            }.value
            guard let self, !Task.isCancelled, self.searchID == id, self.isSearching else { return }
            self.scanReport = report
            self.searchResults = FileSystemService.sort(report.items, field: self.sortField, ascending: self.sortAscending)
            self.selectedIDs = oldSelection.intersection(Set(report.items.map(\.id)))
            self.isBusy = false
            self.statusMessage = needle.isEmpty
                ? L("status.filteredSearch", "找到 %d 项符合条件的结果", report.items.count)
                : L("status.searchResult", "找到 %d 项匹配「%@」的结果", report.items.count, needle)
        }
    }

    func clearSearch() {
        let wasSearching = isSearching
        searchTask?.cancel()
        searchCancellation?.cancel()
        searchID = UUID()
        isSearching = false
        searchQuery = ""
        searchCriteria = FileSearchCriteria()
        searchResults = []
        if wasSearching { isBusy = false; scanReport = FileScanReport(); updateStatus() }
        if wasSearching, items.isEmpty, let directory = currentDirectory { load(directory: directory, resetCategory: false) }
    }

    // MARK: - 状态

    private func updateStatus() {
        let folders = items.filter(\.isContainer).count
        let files = items.count - folders
        statusMessage = String(format: WLocalizedString("status.itemCount", comment: "项目统计"), items.count, folders, files)
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
