import AppKit
import Combine
import Foundation

@MainActor
final class WeChatCleanupModel: ObservableObject {
    private var cachedVisibleFiles: [WeChatFile]?
    @Published private(set) var result = WeChatScanResult() { didSet { cachedVisibleFiles = nil } }
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var hasScanned = false
    @Published var search = "" { didSet { cachedVisibleFiles = nil; selection = [] } }
    @Published var kind = "all" { didSet { cachedVisibleFiles = nil; selection = [] } }
    @Published var minimumMB = 0 { didSet { cachedVisibleFiles = nil; selection = [] } }
    @Published var olderThanDays = 0 { didSet { cachedVisibleFiles = nil; selection = [] } }
    @Published var sort = "size" {
        didSet {
            cachedVisibleFiles = nil
            if sort != oldValue { sortAscending = !["size", "date"].contains(sort) }
        }
    }
    @Published var sortAscending = false { didSet { cachedVisibleFiles = nil } }
    @Published var account = "all" { didSet { cachedVisibleFiles = nil; selection = [] } }
    @Published var month = "all" { didSet { cachedVisibleFiles = nil; selection = [] } }
    @Published var source = "all" { didSet { cachedVisibleFiles = nil; selection = [] } }
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

    var filterState: WeChatFilterState {
        WeChatFilterState(search: search, kind: kind, account: account, month: month, source: source,
                          minimumMB: minimumMB, olderThanDays: olderThanDays, sort: sort, ascending: sortAscending)
    }
    func restoreFilters(_ state: WeChatFilterState?) {
        guard let state else { return }
        search = state.search; kind = state.kind; account = state.account; month = state.month; source = state.source
        minimumMB = max(0, min(state.minimumMB, 1_000_000)); olderThanDays = max(0, min(state.olderThanDays, 36500))
        sort = state.sort; sortAscending = state.ascending
    }

    init(initialResult: WeChatScanResult = WeChatScanResult(),
         homeDirectory: URL = FileSystemService.realHomeDirectory(), customRoots: [URL]? = nil) {
        self.homeDirectory = homeDirectory
        result = initialResult
        hasScanned = !initialResult.roots.isEmpty
        self.customRoots = customRoots ?? (UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    deinit { scanTask?.cancel() }

    private var filteredFiles: [WeChatFile] {
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
    var matchingCount: Int { visibleFiles.count }
    var matchingSize: Int64 { visibleFiles.reduce(0) { $0 + $1.size } }
    var visibleFiles: [WeChatFile] {
        if let cachedVisibleFiles { return cachedVisibleFiles }
        let files = filteredFiles.sorted {
            let comparison: ComparisonResult
            switch sort {
            case "date": comparison = $0.modified.compare($1.modified)
            case "name": comparison = $0.name.localizedStandardCompare($1.name)
            case "type": comparison = $0.typeDescription.localizedStandardCompare($1.typeDescription)
            case "location": comparison = $0.parentPath.localizedStandardCompare($1.parentPath)
            default: comparison = $0.size == $1.size ? .orderedSame : ($0.size < $1.size ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame { return $0.id < $1.id }
            return comparison == (sortAscending ? .orderedAscending : .orderedDescending)
        }
        cachedVisibleFiles = files
        return files
    }
    var selectedFiles: [WeChatFile] {
        guard !selection.isEmpty else { return [] }
        return filteredFiles.filter { selection.contains($0.id) }
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
        let files = visibleFiles
        guard files.indices.contains(row) else { return nil }
        let file = files[row]
        selection = [file.id]
        return FileItem(weChatFile: file)
    }

    func selectForContextMenu(_ ids: Set<String>) {
        // AppKit preserves an existing multi-selection when its row is right-clicked.
        let valid = Set(filteredFiles.map(\.id)).intersection(ids)
        if !valid.isEmpty, !valid.isSubset(of: selection) { selection = valid }
    }

    func requestTrash() {
        guard !isScanning, !isCleaning, !selectedFiles.isEmpty else { return }
        pendingTrashFiles = selectedFiles
        confirmsTrash = true
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
