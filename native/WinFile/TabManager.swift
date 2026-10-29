// 页签管理：一个窗口内管理多个浏览页签（对应 Windows 资源管理器的标签页）
// 独立成可测试的模型，避免逻辑散落在视图里
import AppKit
import Combine
import Foundation

@MainActor
final class WinFileTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var isPinned = false
    let model: BrowserModel
    private var cancellables = Set<AnyCancellable>()

    init(engine: FSEngine, startDirectory: URL?, tabManager: TabManager? = nil) {
        model = BrowserModel(engine: engine, startDirectory: startDirectory)
        model.tabManager = tabManager
        // 页签标题与图标随浏览状态变化而刷新
        model.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var title: String {
        let subtitle = model.windowSubtitle
        return subtitle.isEmpty ? L("tab.untitled", "新标签页") : subtitle
    }

    var symbol: String {
        switch model.selection {
        case .home: return "house.fill"
        case .thisPC: return "pc"
        case .applications: return "square.grid.2x2.fill"
        case .appData: return "shippingbox.fill"
        case .storageCleanup: return "externaldrive.badge.minus"
        case .weChatCleanup: return "externaldrive.badge.minus"
        case .androidDevice: return "candybarphone"
        case .category(let category): return category.symbol
        case .folder(let url):
            return url.path == "/" ? "internaldrive.fill" : "folder.fill"
        case nil: return "folder"
        }
    }

    /// 供页签栏 tooltip 显示的完整路径
    var pathDescription: String {
        model.currentDirectory.map { FileSystemService.abbreviate($0) } ?? title
    }
}

@MainActor
final class TabManager: ObservableObject {

    private static let liveManagers = NSHashTable<TabManager>.weakObjects()
    static var allModels: [BrowserModel] { liveManagers.allObjects.flatMap { $0.tabs.map(\.model) } }

    @Published private(set) var tabs: [WinFileTab] = []
    @Published private(set) var activeID: UUID?
    /// Prevents a drag from one window from reordering another window's tabs.
    let reorderIdentifier = UUID()

    private let engine: FSEngine
    private var cancellables = Set<AnyCancellable>()
    /// 当前活动模型转发的订阅：切换页签时先取消旧的，
    /// 否则非活动页签的每次变化都会触发 TabManager 的全量刷新
    private var modelCancellable: AnyCancellable?
    private weak var observedModel: BrowserModel?

    private let sessionStore: BrowserSessionStore
    private let persistsSession: Bool
    private var includedInSession = true
    private var saveTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var inactiveSince: [UUID: Date] = [:]
    private var recentIDs: [UUID] = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    @Published private(set) var closedTabs: [SavedBrowserTab] = []

    init(engine: FSEngine, startDirectory: URL?, restoreSession: Bool = false, sessionStore: BrowserSessionStore? = nil, persistSession: Bool = false) {
        self.sessionStore = sessionStore ?? .shared
        self.persistsSession = restoreSession || persistSession
        self.engine = engine
        // 始终至少有一个页签，符合资源管理器行为
        let first = WinFileTab(engine: engine, startDirectory: startDirectory, tabManager: self)
        tabs = [first]
        activeID = first.id
        if restoreSession, startDirectory == nil, let saved = self.sessionStore.load() {
            tabs = saved.tabs.map { record in
                let tab = WinFileTab(engine: engine, startDirectory: nil, tabManager: self)
                tab.isPinned = record.pinned ?? false
                record.apply(to: tab.model)
                return tab
            }
            activeID = tabs[min(max(0, saved.activeIndex), tabs.count - 1)].id
            tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        }
        forwardActiveModelChanges()
        Self.liveManagers.add(self)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.reclaimInactiveTabs(immediately: true)
                NotificationCenter.default.post(name: .winFileMemoryPressure, object: nil)
            }
        }
        memoryPressure = pressure
        pressure.resume()
        // 切换页签时改订新模型
        $activeID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.forwardActiveModelChanges(); self?.scheduleSave() }
            .store(in: &cancellables)
    }

    /// 转发「当前页签模型」的变更。
    ///
    /// 这是关键：页签内导航改的是 BrowserModel 的属性，而不是 TabManager 的属性。
    /// 若只观察 TabManager，内容区就收不到通知 ——
    /// 表现为"主页点了文件夹，必须切换页签才看到结果"。
    private func forwardActiveModelChanges() {
        let current = activeModel
        guard observedModel !== current else { return }
        if let previous = recentIDs.last { inactiveSince[previous] = Date() }
        let live = Set(tabs.map(\.id))
        recentIDs.removeAll { $0 == activeID || !live.contains($0) }
        inactiveSince = inactiveSince.filter { live.contains($0.key) }
        if let activeID { recentIDs.append(activeID); inactiveSince[activeID] = nil }
        observedModel = current
        current.resumeReadOnlyResults()
        reclaimInactiveTabs()
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.reclaimInactiveTabs()
        }
        modelCancellable?.cancel()
        modelCancellable = current.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send(); self?.scheduleSave() }
        objectWillChange.send()
    }

    deinit { saveTask?.cancel(); idleTask?.cancel(); memoryPressure?.cancel() }

    func reclaimInactiveTabs(immediately: Bool = false) {
        let warm = Set(recentIDs.suffix(3))
        for tab in tabs where tab.id != activeID {
            if immediately || (!warm.contains(tab.id) && Date().timeIntervalSince(inactiveSince[tab.id] ?? .distantPast) >= 60) {
                tab.model.reclaimReadOnlyResults()
            }
        }
    }

    private func scheduleSave() {
        guard persistsSession else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }
    func persistNow() {
        guard persistsSession else { return }
        if sessionStore === BrowserSessionStore.shared {
            let managers = BrowserWindowCommands.shared.sessionManagers(including: self)
                .filter { $0.persistsSession && $0.includedInSession }
            guard managers.contains(where: { $0 === self }), !managers.isEmpty else { return }
            let allTabs = managers.flatMap(\.tabs)
            sessionStore.save(tabs: allTabs, activeID: activeID)
        } else {
            sessionStore.save(tabs: tabs, activeID: activeID)
        }
    }

    var activeTab: WinFileTab { tabs.first { $0.id == activeID } ?? tabs[0] }
    var activeModel: BrowserModel { activeTab.model }
    var count: Int { tabs.count }
    var canCloseActive: Bool { tabs.count > 1 && !activeTab.isPinned }

    /// 新页签：可指定初始目录；不指定时进入主页
    @discardableResult
    func newTab(startDirectory: URL? = nil, activate: Bool = true) -> WinFileTab {
        TabDiagnostics.shared.record("TabManager.newTab", detail: "原有=\(tabs.count) 目录=\(startDirectory?.lastPathComponent ?? "主页")")
        let tab = WinFileTab(engine: engine, startDirectory: nil, tabManager: self)
        tabs.append(tab)
        if activate { activeID = tab.id }
        if let directory = startDirectory {
            tab.model.selectFolder(directory)
        } else {
            tab.model.navigate(to: .home)
        }
        scheduleSave()
        return tab
    }

    /// 复制某个页签（打开它当前所在目录）
    @discardableResult
    func duplicate(_ tab: WinFileTab) -> WinFileTab {
        let copy = newTab()
        SavedBrowserTab(model: tab.model).apply(to: copy.model)
        return copy
    }

    func select(_ tab: WinFileTab) {
        TabDiagnostics.shared.record("TabManager.select", detail: "数量=\(tabs.count) 目标=\(tab.id.uuidString.prefix(4))")
        guard activeID != tab.id else {
            TabDiagnostics.shared.record("TabManager.select.skipped", detail: "已是活动页签")
            return
        }
        activeID = tab.id
        TabDiagnostics.shared.record("TabManager.select.done",
                                     detail: "活动=\(activeTab.id.uuidString.prefix(4)) 标题=\(activeTab.title)")
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeID = tabs[index].id
    }

    /// 关闭页签；关掉最后一个时会自动补一个新页签
    func close(_ tab: WinFileTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        guard !tab.isPinned else { return }
        rememberClosed(tab)
        if tabs.count == 1 {
            let replacement = WinFileTab(engine: engine, startDirectory: nil, tabManager: self)
            replacement.model.navigate(to: .home)
            tabs = [replacement]
            activeID = replacement.id
            return
        }
        tabs.remove(at: index)
        if activeID == tab.id {
            activeID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// 关闭当前页签（仅剩一个时不做任何事）
    func closeActive() {
        guard canCloseActive else { return }
        close(activeTab)
    }

    func closeOthers(keeping tab: WinFileTab) {
        for other in tabs where other.id != tab.id && !other.isPinned { rememberClosed(other) }
        tabs = tabs.filter { $0.isPinned || $0.id == tab.id }
        activeID = tab.id
        scheduleSave()
    }

    func closeAll() {
        for tab in tabs.filter({ !$0.isPinned }) { close(tab) }
    }

    func togglePin(_ tab: WinFileTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        tab.isPinned.toggle()
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        scheduleSave()
    }

    /// Reordering stays within the pinned or unpinned group and keeps selection intact.
    @discardableResult
    func moveTab(_ id: UUID, over targetID: UUID) -> Bool {
        guard let source = tabs.firstIndex(where: { $0.id == id }),
              let target = tabs.firstIndex(where: { $0.id == targetID }),
              source != target, tabs[source].isPinned == tabs[target].isPinned else { return false }
        var reordered = tabs
        let tab = reordered.remove(at: source)
        reordered.insert(tab, at: target)
        tabs = reordered
        scheduleSave()
        return true
    }

    func canMoveTab(_ tab: WinFileTab, direction: Int) -> Bool {
        guard direction == -1 || direction == 1,
              let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        let neighbor = index + direction
        return tabs.indices.contains(neighbor) && tabs[neighbor].isPinned == tab.isPinned
    }

    func moveTab(_ tab: WinFileTab, direction: Int) {
        guard canMoveTab(tab, direction: direction),
              let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        moveTab(tab.id, over: tabs[index + direction].id)
    }

    /// Transfer the same model so navigation history and ongoing operations survive.
    @discardableResult
    func transfer(_ tab: WinFileTab, to destination: TabManager, replacePlaceholder: Bool = false) -> Bool {
        guard destination !== self, tabs.count > 1 || !includedInSession,
              let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        var remaining = tabs
        remaining.remove(at: index)
        if !remaining.isEmpty {
            tabs = remaining
            if activeID == tab.id { activeID = remaining[min(index, remaining.count - 1)].id }
        }
        tab.model.tabManager = destination
        var targetTabs = replacePlaceholder ? [] : destination.tabs
        let insertion = tab.isPinned ? targetTabs.prefix(while: \.isPinned).count : targetTabs.count
        targetTabs.insert(tab, at: insertion)
        destination.tabs = targetTabs
        destination.activeID = tab.id
        destination.forwardActiveModelChanges()
        if !remaining.isEmpty { forwardActiveModelChanges() }
        destination.scheduleSave()
        scheduleSave()
        return true
    }

    func mergeAll(into destination: TabManager) {
        guard destination !== self else { return }
        includedInSession = false
        let original = tabs
        for tab in original { _ = transfer(tab, to: destination) }
        destination.scheduleSave()
    }

    private func rememberClosed(_ tab: WinFileTab) {
        closedTabs.append(SavedBrowserTab(model: tab.model))
        if closedTabs.count > 20 { closedTabs.removeFirst() }
    }

    func restoreClosedTab() {
        guard let saved = closedTabs.popLast() else { return }
        let tab = newTab()
        saved.apply(to: tab.model)
    }

    func visibleTabs(width: CGFloat) -> [WinFileTab] {
        let capacity = max(1, Int(max(0, width - 84) / 160))
        var visible = Array(tabs.prefix(capacity))
        if !visible.contains(where: { $0.id == activeID }), let active = tabs.first(where: { $0.id == activeID }) {
            visible[visible.count - 1] = active
        }
        return visible
    }
}

extension Notification.Name { static let winFileMemoryPressure = Notification.Name("WinFileMemoryPressure") }
