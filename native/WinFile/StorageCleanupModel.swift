import AppKit
import Combine
import Foundation

struct StorageCleanupHistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let count: Int
    let bytes: Int64
    let failures: Int
    let cancelled: Bool
    var softwareName: String?
}

struct SoftwareCleanupApp: Identifiable {
    static let otherSourceID = "__winfile_other_apps__"
    let id: String
    let name: String
    var title: String { id == "wechat" ? L("software.wechat", "微信") : name }

    /// Returns a display name or the stable key for unidentified applications.
    /// Presentation only: keep the original bundle ID and scan rule intact for
    /// app isolation, running-process checks and trash revalidation.
    static func sourceName(id: String, fallback: String, resolve: (String) -> String? = AppDataService.resolvedName) -> String {
        if isVisible(id: id, name: fallback) { return fallback }
        if let name = resolve(id), isVisible(id: id, name: name) { return name }
        // A helper can belong to a known app even when LaunchServices cannot
        // resolve the helper itself. Only use an ancestor with a resolved name.
        var parts = id.split(separator: ".").map(String.init)
        while parts.count > 3 {
            parts.removeLast()
            let parent = parts.joined(separator: ".")
            if let name = resolve(parent), isVisible(id: parent, name: name) { return name }
        }
        return otherSourceID
    }

    static func isVisible(id: String, name: String) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.lowercased() != id.lowercased(),
              !AppDataService.looksLikeBundleID(title) else { return false }
        let components = id.lowercased().split(separator: ".").map(String.init)
        let helperTerms = ["helper", "updater", "installer", "findersync", "quicklook", "shipit",
                           "loginitem", "widget", "extension", "mountprovider", "thumbnail"]
        guard !components.contains(where: { part in helperTerms.contains { part.contains($0) } }),
              !["agent", "daemon", "xpc", "preview", "share", "settings", "preferences"].contains(components.last ?? "") else { return false }
        let lower = title.lowercased()
        return !helperTerms.contains(where: { lower.contains($0) })
            && !["settings", "preference", "preferences"].contains(where: { lower.hasSuffix($0) })
            && !["辅助程序", "更新程序", "安装程序", "登录项", "扩展程序"].contains(where: { title.contains($0) })
            && !lower.hasPrefix("winfile-install-")
    }
}

@MainActor
final class StorageCleanupModel: ObservableObject {
    struct Display {
        var filtered: [StorageCleanupFile] = []
        var rows: [StorageCleanupFile] = []
        var page = 0
        var pages = 1
        var bytes: Int64 = 0
    }
    static let pageSize = 200
    @Published private(set) var result = StorageCleanupScanResult()
    @Published private(set) var display = Display()
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var progress = StorageCleanupProgress()
    @Published private(set) var cleaningIndex = 0
    @Published var selection = Set<String>()
    @Published var search = "" { didSet { if search != oldValue { filtersChanged() } } }
    @Published var category = "all" { didSet { if category != oldValue { filtersChanged() } } }
    @Published var owner = "all" { didSet { if owner != oldValue { filtersChanged() } } }
    @Published var sort = "size" { didSet { rebuild() } }
    @Published var confirmsTrash = false
    @Published var scanScope = "all"
    @Published var minimumAgeDays = 7
    @Published var minimumLargeMB = 100
    @Published private(set) var largeFolder: URL?
    @Published private(set) var downloadFolder: URL?
    @Published private(set) var ignored: [URL]
    @Published private(set) var history: [StorageCleanupHistoryEntry]
    @Published private(set) var message: String?
    let softwareMode: Bool
    @Published private(set) var softwareChoices: [SoftwareCleanupApp] = []
    @Published private(set) var selectedSoftwareID = "wechat"
    private(set) var pendingFiles: [StorageCleanupFile] = []
    private let home: URL
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var configurationAtScan: StorageCleanupConfiguration?
    private var sourceNames: [String: String] = [:]
    private var sourceLanguage = ""
    private static let ignoreKey = "StorageCleanup.ignored.v1"
    private static let historyKey = "StorageCleanup.history.v1"
    private static let downloadFolderKey = "StorageCleanup.baiduDownloadFolder.v1"

    init(home: URL = FileSystemService.realHomeDirectory(), defaults: UserDefaults = .standard, softwareMode: Bool = false) {
        self.home = home.resolvingSymlinksInPath(); self.defaults = defaults; self.softwareMode = softwareMode
        ignored = (defaults.stringArray(forKey: Self.ignoreKey) ?? []).map { URL(fileURLWithPath: $0) }
        downloadFolder = defaults.string(forKey: Self.downloadFolderKey).map { URL(fileURLWithPath: $0) }
        if let data = defaults.data(forKey: Self.historyKey), let value = try? JSONDecoder().decode([StorageCleanupHistoryEntry].self, from: data) {
            history = Array(value.prefix(30))
        } else { history = [] }
        if softwareMode { refreshSoftwareChoices() }
    }
    deinit { task?.cancel() }
    var busy: Bool { isScanning || isCleaning }
    var isBaidu: Bool { softwareMode && selectedSoftwareID == StorageCleanupService.baiduBundleID }
    var availableKinds: [StorageCleanupKind] { softwareMode ? (isBaidu ? [.download, .cache, .log] : [.cache, .log]) : StorageCleanupKind.allCases }
    var folderPickerTitle: String { isBaidu ? L("software.baiduChooseFolder", "选择百度网盘下载目录…") : L("cleanup.chooseFolder", "选择大文件扫描目录…") }
    var downloadScopeDescription: String {
        let roots = StorageCleanupService.baiduDownloadRoots(configuration)
        return roots.isEmpty ? L("software.baiduMissing", "未找到常见下载目录，请选择百度网盘实际使用的下载文件夹。") : roots.map(\.path).joined(separator: "\n")
    }
    var softwareTitle: String { softwareChoices.first { $0.id == selectedSoftwareID }?.title ?? selectedSoftwareID }
    func refreshSoftwareChoices() {
        guard softwareMode, !busy else { return }
        let names = ["com.google.chrome": "Google Chrome", "com.microsoft.edgemac": "Microsoft Edge",
                     "com.brave.browser": "Brave", "com.microsoft.vscode": "Visual Studio Code",
                     "com.tinyspeck.slackmacgap": "Slack", "com.hnc.discord": "Discord",
                     "com.microsoft.teams2": "Microsoft Teams", "com.baidu.netdisk": L("software.baidu", "百度网盘")]
        var apps: [String: SoftwareCleanupApp] = [:]
        let config = StorageCleanupConfiguration(home: home, downloadFolder: downloadFolder, kinds: [.cache, .log, .download])
        for rule in StorageCleanupService.rules(config) {
            guard let rawID = rule.bundleID else { continue }
            let id = rawID.lowercased()
            guard !id.hasPrefix("com.tencent.xinwechat"), !id.hasPrefix("com.tencent.wechat") else { continue }
            let name = names[id] ?? rule.owner
            guard SoftwareCleanupApp.isVisible(id: id, name: name) else { continue }
            apps[id] = SoftwareCleanupApp(id: id, name: name)
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: StorageCleanupService.baiduBundleID) != nil {
            apps[StorageCleanupService.baiduBundleID] = SoftwareCleanupApp(id: StorageCleanupService.baiduBundleID, name: L("software.baidu", "百度网盘"))
        }
        // Keep an already selected source visible even if its last cache was removed.
        if selectedSoftwareID != "wechat", apps[selectedSoftwareID] == nil,
           let selected = softwareChoices.first(where: { $0.id == selectedSoftwareID }),
           SoftwareCleanupApp.isVisible(id: selected.id, name: selected.name) { apps[selectedSoftwareID] = selected }
        softwareChoices = [SoftwareCleanupApp(id: "wechat", name: "WeChat")] + apps.values.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    @discardableResult
    func selectSoftware(_ id: String) -> Bool {
        guard softwareMode, !isCleaning, softwareChoices.contains(where: { $0.id == id }) else { return false }
        guard id != selectedSoftwareID else { return true }
        task?.cancel(); task = nil; generation = UUID(); isScanning = false
        selectedSoftwareID = id
        result = StorageCleanupScanResult(); display = Display(); progress = StorageCleanupProgress()
        selection = []; pendingFiles = []; confirmsTrash = false; configurationAtScan = nil
        hasScanned = false; message = nil; search = ""; category = "all"; owner = "all"; scanScope = "all"
        return true
    }
    var configuration: StorageCleanupConfiguration {
        StorageCleanupConfiguration(home: home, largeFolder: largeFolder, downloadFolder: downloadFolder,
                                    weChatFolders: (defaults.stringArray(forKey: WeChatCleanupService.customRootsPreferenceKey) ?? []).map { URL(fileURLWithPath: $0) }, ignored: ignored,
                                    kinds: (StorageCleanupKind(rawValue: scanScope).map { Set([$0]) } ?? Set(availableKinds)).intersection(availableKinds),
                                    bundleIDs: softwareMode ? (selectedSoftwareID == "wechat" ? [] : [selectedSoftwareID]) : nil,
                                    minimumAgeDays: minimumAgeDays, minimumLargeBytes: Int64(minimumLargeMB) * 1024 * 1024)
    }
    var owners: [String] {
        var values = Set(result.files.map { sourceOwner(for: $0) })
        if owner != "all" { values.insert(owner) }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var selectedFiles: [StorageCleanupFile] { result.files.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { result.files.reduce(0) { $0 + $1.size } }
    private func sourceOwner(for file: StorageCleanupFile) -> String {
        guard let id = file.rule.bundleID else { return file.rule.owner }
        let language = Localization.languageCode
        if sourceLanguage != language { sourceNames = [:]; sourceLanguage = language }
        let key = id + "\n" + file.rule.owner
        if let name = sourceNames[key] { return name }
        let name = SoftwareCleanupApp.sourceName(id: id, fallback: file.rule.owner)
        sourceNames[key] = name
        return name
    }
    func displayOwner(for file: StorageCleanupFile) -> String {
        file.rule.bundleID == nil ? file.rule.owner : ownerTitle(sourceOwner(for: file))
    }
    func ownerTitle(_ value: String) -> String {
        if value == SoftwareCleanupApp.otherSourceID { return L("cleanup.otherApps", "其他应用") }
        // Also cover an existing filter whose source disappeared after a scan.
        if AppDataService.looksLikeBundleID(value) {
            let name = SoftwareCleanupApp.sourceName(id: value, fallback: value)
            return name == SoftwareCleanupApp.otherSourceID ? L("cleanup.otherApps", "其他应用") : name
        }
        return value
    }
    func accept(_ result: StorageCleanupScanResult) {
        self.result = result; sourceNames = [:]; hasScanned = true
        selection.formIntersection(Set(result.files.map(\.id)))
        rebuild()
    }
    private func filtersChanged() {
        discardPendingTrash()
        rebuild()
    }
    func rebuild(page: Int = 0) {
        var filtered = result.files.filter {
            (category == "all" || $0.rule.kind.rawValue == category) && (owner == "all" || sourceOwner(for: $0) == owner)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.url.path.localizedCaseInsensitiveContains(search))
        }
        filtered.sort {
            switch sort {
            case "name": return $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case "date": return $0.modified == $1.modified ? $0.id < $1.id : $0.modified < $1.modified
            default: return $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size
            }
        }
        let pages = max(1, (filtered.count + Self.pageSize - 1) / Self.pageSize)
        let page = min(max(0, page), pages - 1)
        let start = page * Self.pageSize
        display = Display(filtered: filtered, rows: Array(filtered.dropFirst(start).prefix(Self.pageSize)),
                          page: page, pages: pages, bytes: filtered.reduce(0) { $0 + $1.size })
    }
    func selectAll() { selection = Set(display.filtered.map(\.id)) }
    @discardableResult
    func chooseFolder(_ url: URL) -> Bool {
        guard !busy else { return false }
        let target = url.resolvingSymlinksInPath()
        guard StorageCleanupService.allowedLargeFolder(target, home: home) else {
            message = L("cleanup.invalidFolder", "请选择个人文件夹内的普通子目录；不支持个人文件夹根目录、Library、隐藏目录或应用包。")
            return false
        }
        if isBaidu {
            downloadFolder = target
            defaults.set(target.path, forKey: Self.downloadFolderKey)
            resetDownloadScan()
        } else { largeFolder = target }
        hasScanned = false
        return true
    }
    func useDefaultDownloadFolders() {
        guard !busy else { return }
        downloadFolder = nil; defaults.removeObject(forKey: Self.downloadFolderKey)
        resetDownloadScan()
    }
    private func resetDownloadScan() {
        result = StorageCleanupScanResult(); display = Display(); progress = StorageCleanupProgress()
        selection = []; pendingFiles = []; confirmsTrash = false; configurationAtScan = nil; hasScanned = false
        search = ""; category = "all"; owner = "all"; scanScope = "all"; message = nil
    }
    func useDefaultFolders() { guard !busy else { return }; largeFolder = nil; hasScanned = false }
    func ignore(_ url: URL) {
        guard !busy else { return }
        let url = url.standardizedFileURL
        if !ignored.contains(url) { ignored.append(url) }
        defaults.set(ignored.map(\.path), forKey: Self.ignoreKey)
        result.files.removeAll { StorageCleanupService.contains($0.url, in: url) }
        selection.formIntersection(Set(result.files.map(\.id))); rebuild()
    }
    func removeIgnore(_ url: URL) {
        guard !busy else { return }
        ignored.removeAll { $0 == url }; defaults.set(ignored.map(\.path), forKey: Self.ignoreKey)
        hasScanned = false
    }
    func cancel() { task?.cancel() }
    func scan() {
        guard !busy else { return }
        let id = UUID(); generation = id
        let config = configuration; configurationAtScan = config
        let running = StorageCleanupService.runningBundleIDs()
        isScanning = true; message = nil; selection = []; progress = StorageCleanupProgress()
        task = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                StorageCleanupService.scan(config, running: running, cancelled: { Task.isCancelled }) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, self.isScanning else { return }
                        self.progress = value
                    }
                }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, self.generation == id else { return }
            self.accept(result); self.isScanning = false; self.task = nil
        }
    }
    func requestTrash(_ ids: Set<String>? = nil) {
        guard !busy else { return }
        if let ids { selection = ids }
        pendingFiles = selectedFiles
        confirmsTrash = !pendingFiles.isEmpty
    }
    func discardPendingTrash() {
        guard !isCleaning else { return }
        selection = []; pendingFiles = []; confirmsTrash = false
    }
    func clean() {
        guard !busy, !FileOperationHistory.shared.isBusy, !pendingFiles.isEmpty, var config = configurationAtScan else { return }
        let files = pendingFiles; pendingFiles = []
        // The confirmed scan fixes the eligibility settings; the current ignore
        // list can only further restrict that plan.
        config.ignored = ignored; config.now = Date()
        isCleaning = true; message = nil; cleaningIndex = 0
        task = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                StorageCleanupService.trash(files, config: config, cancelled: { Task.isCancelled }) { index in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCleaning else { return }
                        self.cleaningIndex = index
                    }
                }
            }
            let outcome = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self else { return }
            self.result.removeTrashedFiles(outcome.removed)
            self.selection.subtract(outcome.removed); self.rebuild()
            FileOperationHistory.shared.record(title: self.softwareMode ? self.softwareTitle : L("cleanup.title", "空间清理"), moves: outcome.moves)
            let entry = StorageCleanupHistoryEntry(date: Date(), count: outcome.removed.count, bytes: outcome.bytes,
                                                   failures: outcome.failures.count, cancelled: outcome.cancelled,
                                                   softwareName: self.softwareMode ? self.softwareTitle : nil)
            self.history.insert(entry, at: 0); self.history = Array(self.history.prefix(30))
            if let data = try? JSONEncoder().encode(self.history) { self.defaults.set(data, forKey: Self.historyKey) }
            self.message = L("cleanup.outcome", "已移到废纸篓 %d 项（%@），跳过或失败 %d 项。", outcome.removed.count,
                             FileItem.formatSize(outcome.bytes), outcome.failures.count)
                + (outcome.cancelled ? "\n" + L("cleanup.cancelled", "已取消，结果不完整。") : "")
                + (outcome.failures.isEmpty ? "" : "\n" + outcome.failures.joined(separator: "\n"))
            self.isCleaning = false; self.task = nil
        }
    }
}
