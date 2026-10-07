// 页签管理：一个窗口内管理多个浏览页签（对应 Windows 资源管理器的标签页）
// 独立成可测试的模型，避免逻辑散落在视图里
import Combine
import Foundation

@MainActor
final class WinFileTab: ObservableObject, Identifiable {
    let id = UUID()
    let model: BrowserModel
    private var cancellables = Set<AnyCancellable>()

    init(engine: FSEngine, startDirectory: URL?) {
        model = BrowserModel(engine: engine, startDirectory: startDirectory)
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

    @Published private(set) var tabs: [WinFileTab] = []
    @Published private(set) var activeID: UUID?

    private let engine: FSEngine
    private var cancellables = Set<AnyCancellable>()
    private weak var observedModel: BrowserModel?

    init(engine: FSEngine, startDirectory: URL?) {
        self.engine = engine
        // 始终至少有一个页签，符合资源管理器行为
        let first = WinFileTab(engine: engine, startDirectory: startDirectory)
        tabs = [first]
        activeID = first.id
        forwardActiveModelChanges()
        // 切换页签时改订新模型
        $activeID
            .sink { [weak self] _ in self?.forwardActiveModelChanges() }
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
        observedModel = current
        current.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        objectWillChange.send()
    }

    var activeTab: WinFileTab { tabs.first { $0.id == activeID } ?? tabs[0] }
    var activeModel: BrowserModel { activeTab.model }
    var count: Int { tabs.count }
    var canCloseActive: Bool { tabs.count > 1 }

    /// 新页签：可指定初始目录；不指定时进入主页
    @discardableResult
    func newTab(startDirectory: URL? = nil, activate: Bool = true) -> WinFileTab {
        TabDiagnostics.shared.record("TabManager.newTab", detail: "原有=\(tabs.count) 目录=\(startDirectory?.lastPathComponent ?? "主页")")
        let tab = WinFileTab(engine: engine, startDirectory: nil)
        tabs.append(tab)
        if activate { activeID = tab.id }
        if let directory = startDirectory {
            tab.model.selectFolder(directory)
        } else {
            tab.model.navigate(to: .home)
        }
        return tab
    }

    /// 复制某个页签（打开它当前所在目录）
    @discardableResult
    func duplicate(_ tab: WinFileTab) -> WinFileTab {
        newTab(startDirectory: tab.model.currentDirectory)
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
        tabs.remove(at: index)
        if tabs.isEmpty {
            let replacement = WinFileTab(engine: engine, startDirectory: nil)
            replacement.model.navigate(to: .home)
            tabs = [replacement]
            activeID = replacement.id
            return
        }
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
        tabs = [tab]
        activeID = tab.id
    }

    func closeAll() {
        closeActive()
        while tabs.count > 1 { close(tabs[1]) }
    }
}
