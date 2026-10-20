import AppKit
import Combine
import Foundation

@MainActor
final class WeChatCleanupModel: ObservableObject {
    /// 排序状态：字段与方向合并为一个原子值。
    ///
    /// 之前分成 sort / sortAscending 两个 @Published，一次表头点击会连续发布
    /// 三次变更（sort → didSet 改方向 → 绑定再写方向），等于让 SwiftUI 表格
    /// 连续做三轮全量行差异计算，显著放大卡死风险。
    struct SortState: Equatable {
        var field: String = "size"
        var ascending: Bool = false

        /// 切换到新字段时的默认方向：大小/日期默认降序，其余升序
        static func defaultAscending(for field: String) -> Bool {
            !["size", "date"].contains(field)
        }

        init(field: String = "size", ascending: Bool? = nil) {
            self.field = field
            self.ascending = ascending ?? Self.defaultAscending(for: field)
        }
    }

    /// 每页行数。
    ///
    /// SwiftUI 表格在“整表重排”时会把所有行做成一次 diff；8 千多行时
    /// 这套 diff 偶发不收敛（实测 CPU 100% 永久卡死，栈在
    /// AppKitOutlineTableCoordinator → remove(atOffsets:)）。
    /// 分页把一次 diff 压到 200 行，从规模上规避该问题。
    static let pageSize = 200

    @Published private(set) var result = WeChatScanResult() { didSet { apply() } }
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var hasScanned = false
    @Published var search = "" { didSet { filtersChanged() } }
    @Published var kind = "all" { didSet { filtersChanged() } }
    @Published var minimumMB = 0 { didSet { filtersChanged() } }
    @Published var olderThanDays = 0 { didSet { filtersChanged() } }
    @Published var account = "all" { didSet { filtersChanged() } }
    @Published var month = "all" { didSet { filtersChanged() } }
    @Published var source = "all" { didSet { filtersChanged() } }

    /// 一次排序交互产生的全部显示状态。
    ///
    /// 合并成一个快照赋值，是为了**每次排序只发布一次 objectWillChange**：
    /// 之前排序状态、结果、页码、当前页各自是 @Published，一次点击会连续发布
    /// 多次，让 SwiftUI 反复做全表 diff —— 正是卡死的放大因素。
    struct Display: Equatable {
        var sortState = SortState()
        var visibleFiles: [WeChatFile] = []   // 全量筛选+排序（跨页）
        var page = 0                          // 当前页（0 基）
        var pagedFiles: [WeChatFile] = []     // 当前页的行（表格只渲染这些）
    }

    @Published private(set) var display = Display()

    var sortState: SortState { display.sortState }
    var visibleFiles: [WeChatFile] { display.visibleFiles }
    var page: Int { display.page }
    var pagedFiles: [WeChatFile] { display.pagedFiles }

    /// 筛选结果缓存（选中项统计复用，避免每帧全量过滤）
    private var filteredCache: [WeChatFile] = []
    /// 批量修改筛选条件时挂起重算，最后只重算一次
    private var suspendRebuild = false
    @Published private(set) var scanProgress = WeChatScanProgress()
    var accounts: [String] { Array(Set(result.files.map(\.accountID))).sorted() }
    var months: [String] { Array(Set(result.files.map(\.month))).sorted(by: >) }
    @Published var selection: Set<String> = []
    @Published var message: String?
    @Published var confirmsTrash = false
    private(set) var pendingTrashFiles: [WeChatFile] = []
    private let homeDirectory: URL
    @Published private(set) var customRoots: [URL]
    private var scanTask: Task<WeChatScanResult, Never>?
    private var scanID = UUID()
    private static let rootsKey = "WeChatCleanupFolders"
    @Published private(set) var lastScanDate: Date?

    /// 兼容访问器：写入时走统一的 setSort，保证只发布一次
    var sort: String {
        get { sortState.field }
        set { setSort(field: newValue, ascending: SortState.defaultAscending(for: newValue)) }
    }
    var sortAscending: Bool {
        get { sortState.ascending }
        set { setSort(field: sortState.field, ascending: newValue) }
    }

    init(initialResult: WeChatScanResult = WeChatScanResult(),
         homeDirectory: URL = FileSystemService.realHomeDirectory(), customRoots: [URL]? = nil) {
        self.homeDirectory = homeDirectory
        self.result = initialResult
        hasScanned = !initialResult.roots.isEmpty
        self.customRoots = customRoots ?? (UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []).map { URL(fileURLWithPath: $0) }
        apply()
    }

    deinit { scanTask?.cancel() }

    /// 切换排序：计算完成后一次性提交，只发布一次
    func setSort(field: String, ascending: Bool) {
        let next = SortState(field: field, ascending: ascending)
        guard next != display.sortState else { return }
        apply(sortState: next, resetPage: true)
    }

    var filterState: WeChatFilterState {
        WeChatFilterState(search: search, kind: kind, account: account, month: month, source: source,
                          minimumMB: minimumMB, olderThanDays: olderThanDays,
                          sort: display.sortState.field, ascending: display.sortState.ascending)
    }
    func restoreFilters(_ state: WeChatFilterState?) {
        guard let state else { return }
        suspendRebuild = true
        defer {
            suspendRebuild = false
            // 排序字段/方向也属于会话状态，必须一起恢复
            apply(sortState: SortState(field: state.sort, ascending: state.ascending), resetPage: true)
        }
        search = state.search; kind = state.kind; account = state.account; month = state.month; source = state.source
        minimumMB = max(0, min(state.minimumMB, 1_000_000)); olderThanDays = max(0, min(state.olderThanDays, 36500))
    }

    // MARK: - 重算

    /// 筛选条件变化：清空选择、回到第一页，再重算
    private func filtersChanged() {
        selection = []
        guard !suspendRebuild else { return }
        apply(resetPage: true)
    }

    /// 重算筛选、排序、分页并一次性提交。
    private func apply(sortState: SortState? = nil, resetPage: Bool = false) {
        var next = Display()
        next.sortState = sortState ?? display.sortState
        if !resetPage { next.page = display.page }

        let filtered = applyFilters()
        filteredCache = filtered
        next.visibleFiles = sortedFiles(filtered, using: next.sortState)

        let pages = max(1, (next.visibleFiles.count + Self.pageSize - 1) / Self.pageSize)
        next.page = min(max(0, next.page), pages - 1)
        next.pagedFiles = pageSlice(next.visibleFiles, page: next.page)

        display = next        // 单次发布
    }

    private func applyFilters() -> [WeChatFile] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? Date()
        return result.files.filter {
            (kind == "all" || $0.kind.rawValue == kind)
                && (account == "all" || $0.accountID == account)
                && (month == "all" || $0.month == month)
                && (source == "all" || (source == "cache" ? $0.isCache : !$0.isCache))
                && $0.size >= Int64(minimumMB) * 1024 * 1024
                && (olderThanDays == 0 || $0.modified < cutoff)
                && (search.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
    }

    /// 排序：先全局排好再切页，保证翻页顺序正确
    private func sortedFiles(_ files: [WeChatFile], using sortState: SortState) -> [WeChatFile] {
        let field = sortState.field
        let ascending = sortState.ascending
        return files.sorted {
            let comparison: ComparisonResult
            switch field {
            case "date": comparison = $0.modified.compare($1.modified)
            case "name": comparison = $0.name.localizedStandardCompare($1.name)
            case "type": comparison = $0.typeDescription.localizedStandardCompare($1.typeDescription)
            case "location": comparison = $0.parentPath.localizedStandardCompare($1.parentPath)
            default: comparison = $0.size == $1.size ? .orderedSame : ($0.size < $1.size ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame { return $0.id < $1.id }
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private func pageSlice(_ files: [WeChatFile], page: Int) -> [WeChatFile] {
        let start = page * Self.pageSize
        guard start < files.count else { return [] }
        return Array(files[start..<min(start + Self.pageSize, files.count)])
    }

    // MARK: - 分页

    var pageCount: Int { max(1, (visibleFiles.count + Self.pageSize - 1) / Self.pageSize) }
    var canGoPrevious: Bool { page > 0 }
    var canGoNext: Bool { page + 1 < pageCount }
    /// 当前页展示的区间（1 基，用于状态栏文案）
    var pageRange: (first: Int, last: Int) {
        guard !pagedFiles.isEmpty else { return (0, 0) }
        return (page * Self.pageSize + 1, page * Self.pageSize + pagedFiles.count)
    }

    func goToPage(_ target: Int) {
        let clamped = min(max(0, target), pageCount - 1)
        guard clamped != page else { return }
        var next = display
        next.page = clamped
        next.pagedFiles = pageSlice(next.visibleFiles, page: clamped)
        display = next      // 单次发布
    }

    func nextPage() { goToPage(page + 1) }
    func previousPage() { goToPage(page - 1) }

    // MARK: - 统计

    var matchingCount: Int { visibleFiles.count }
    var matchingSize: Int64 { visibleFiles.reduce(0) { $0 + $1.size } }
    var selectedFiles: [WeChatFile] {
        guard !selection.isEmpty else { return [] }
        return filteredCache.filter { selection.contains($0.id) }
    }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { result.files.reduce(0) { $0 + $1.size } }

    struct UsageBucket: Identifiable {
        let id: String
        let title: String
        let count: Int
        let bytes: Int64
    }
    func usageBuckets(byMonth: Bool) -> [UsageBucket] {
        Dictionary(grouping: visibleFiles, by: { byMonth ? $0.month : $0.kind.rawValue }).map { key, files in
            UsageBucket(id: key, title: byMonth ? key : (WeChatFileKind(rawValue: key)?.title ?? key),
                        count: files.count, bytes: files.reduce(0) { $0 + $1.size })
        }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case search, kind, account, month, source, size, age
        var id: String { rawValue }
    }

    var activeFilters: [Filter] {
        Filter.allCases.filter {
            switch $0 {
            case .search: return !search.isEmpty
            case .kind: return kind != "all"
            case .account: return account != "all"
            case .month: return month != "all"
            case .source: return source != "all"
            case .size: return minimumMB != 0
            case .age: return olderThanDays != 0
            }
        }
    }

    var advancedFilterCount: Int { activeFilters.filter { $0 != .search && $0 != .kind }.count }

    func filterTitle(_ filter: Filter) -> String {
        switch filter {
        case .search: return L("wechat.filter.name", "名称：%@", search)
        case .kind: return L("wechat.filter.type", "类型：%@", WeChatFileKind(rawValue: kind)?.title ?? kind)
        case .account: return L("wechat.filter.account", "账号：%@", account == "custom" ? L("wechat.customAccount", "其它 / 自定义位置") : account)
        case .month: return L("wechat.filter.month", "月份：%@", month)
        case .source: return source == "cache" ? L("wechat.caches", "缓存 / 缩略图") : L("wechat.attachments", "聊天附件")
        case .size: return L("wechat.filter.size", "至少 %@", FileItem.formatSize(Int64(minimumMB) * 1024 * 1024))
        case .age: return L("wechat.days", "%d 天以前", olderThanDays)
        }
    }

    func clearFilter(_ filter: Filter) {
        switch filter {
        case .search: search = ""
        case .kind: kind = "all"
        case .account: account = "all"
        case .month: month = "all"
        case .source: source = "all"
        case .size: minimumMB = 0
        case .age: olderThanDays = 0
        }
    }

    func resetFilters() { for filter in activeFilters { clearFilter(filter) } }

    func itemForActivation(at row: Int) -> FileItem? {
        guard !isScanning, !isCleaning else { return nil }
        // 表格渲染的是当前页，行号对应 pagedFiles
        let files = pagedFiles
        guard files.indices.contains(row) else { return nil }
        let file = files[row]
        selection = [file.id]
        return FileItem(weChatFile: file)
    }

    func selectForContextMenu(_ ids: Set<String>) {
        // AppKit preserves an existing multi-selection when its row is right-clicked.
        let valid = Set(filteredCache.map(\.id)).intersection(ids)
        if !valid.isEmpty, !valid.isSubset(of: selection) { selection = valid }
    }

    func requestTrash() {
        guard !isScanning, !isCleaning, !selectedFiles.isEmpty else { return }
        pendingTrashFiles = selectedFiles
        confirmsTrash = true
    }

    func discardPendingTrash() {
        guard !isCleaning else { return }
        selection = []; pendingTrashFiles = []; confirmsTrash = false
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = L("wechat.chooseHint", "选择微信数据目录或聊天附件文件夹。此文件夹内的普通文件将列为清理候选。")
        panel.prompt = L("settings.choose", "选择…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if !customRoots.contains(canonical) { customRoots.append(canonical) }
        saveRoots()
        scan()
    }

    func removeFolder(_ root: URL) {
        customRoots.removeAll { $0 == root }
        saveRoots()
        scan()
    }

    private func saveRoots() { UserDefaults.standard.set(customRoots.map(\.path), forKey: Self.rootsKey) }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        selection = []
        message = nil
        scanProgress = WeChatScanProgress()
        let id = UUID()
        scanID = id
        let explicit = customRoots
        let homeDirectory = homeDirectory
        let update: @Sendable (WeChatScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.scanID == id, self.isScanning else { return }
                self.scanProgress = progress
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            let discovery = WeChatCleanupService.discoverRoots(home: homeDirectory)
            var scanned = WeChatCleanupService.scan(roots: discovery.roots, explicitRoots: explicit,
                                                    cancelled: { Task.isCancelled }, onProgress: update)
            scanned.inaccessible = Array(Set(scanned.inaccessible + discovery.inaccessible)).sorted()
            return scanned
        }
        scanTask = task
        Task { [weak self] in
            let scanned = await task.value
            guard let self, self.scanID == id else { return }
            self.result = scanned
            self.isScanning = false
            self.hasScanned = true
            self.lastScanDate = Date()
            self.scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        isScanning = false
    }

    func clean(_ confirmedFiles: [WeChatFile]) {
        guard !isCleaning, !isScanning, !confirmedFiles.isEmpty else { return }
        isCleaning = true
        message = nil
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                WeChatCleanupService.trash(confirmedFiles)
            }.value
            guard let self else { return }
            self.result.files.removeAll { outcome.removed.contains($0.id) }
            self.selection.subtract(outcome.removed)
            self.isCleaning = false
            self.message = L("wechat.cleaned", "已移到废纸篓 %d 项；跳过或失败 %d 项。", outcome.removed.count, outcome.failures.count)
                + (outcome.failures.isEmpty ? "" : "\n" + outcome.failures.joined(separator: "\n"))
        }
    }
}
