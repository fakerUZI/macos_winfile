// 主界面：侧边栏 + 命令栏 + 地址栏（面包屑/补全）+ 文件列表 + 详细信息窗格
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var engine: FSEngine
    /// 自动化渲染（截图/测试）时置为 true，跳过 onAppear 的自动导航，避免覆盖预设状态
    var skipAutoNavigation: Bool = false
    /// 页签管理（一个窗口内可开多个页签）
    @StateObject private var tabManager: TabManager
    @State private var showInspector = true
    @State private var dialog: DialogKind?
    @State private var pathText = ""
    @State private var suggestions: [PathSuggestion] = []
    @State private var editingPath = false
    @State private var searchText = ""
    @FocusState private var pathFieldFocused: Bool

    /// 兼容旧测试入口
    static var currentTabManager: TabManager? { WindowBridge.shared.tabManager }
    /// 外层视图（承载标题/命令栏/地址栏）的求值次数，供验证刷新是否发生
    static var outerBodyEvaluations = 0

    init(engine: FSEngine, skipAutoNavigation: Bool = false) {
        self.engine = engine
        self.skipAutoNavigation = skipAutoNavigation
        let start = UserDefaults.standard.string(forKey: "StartFolderPath").flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        let manager = TabManager(engine: engine, startDirectory: start)
        _tabManager = StateObject(wrappedValue: manager)
        _reader = StateObject(wrappedValue: ActiveTabReader(manager: manager))
    }

    /// 当前页签读取器：界面所有位置都通过它取模型，
    /// 保证观察到的实例与 TabManager 正在使用的实例始终一致。
    @StateObject private var reader: ActiveTabReader

    /// 当前活动页签与模型
    private var activeTab: WinFileTab { reader.tab }
    private var model: BrowserModel { reader.model }
    private var tabs: [WinFileTab] { reader.tabs }

    /// 页签切换后无需手工同步：reader 会自行重新绑定
    private func adopt(_ tab: WinFileTab) { _ = tab }

    /// 三栏布局：侧边栏 / 内容（含页签栏）/ 详细信息
    private var splitLayout: some View {
        HStack(spacing: 0) {
            // 关键：把「每个页签的视图子树」绑定到页签身份。
            // 否则切换页签时 SwiftUI 复用同一份视图身份，
            // 子视图持有的 @ObservedObject / List 内部选中态不会随新模型刷新，
            // 表现为「切换不生效、内容还是旧的」。
            sidebarPane.id(activeTab.id)
            Divider()
            contentPane.id(activeTab.id)
            inspectorPane.id(activeTab.id)
        }
    }

    private var sidebarPane: some View {
        SidebarView(engine: engine, model: model)
            .frame(width: 216)
    }

    private var contentPane: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            commandBar
            Divider()
            addressBar
            Divider()
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var inspectorPane: some View {
        if showInspector {
            Divider()
            InspectorView(engine: engine, model: model)
                .frame(width: 264)
        }
    }

    /// 启动时的初始位置（可在设置中指定）
    private var defaultStartDirectory: URL? {
        UserDefaults.standard.string(forKey: "StartFolderPath").flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
    }

    /// 窗口副标题（搜索态显示提示）
    private var windowSubtitleSuffix: String {
        model.isSearching ? L("search.inFolder", "搜索结果") : ""
    }

    var body: some View {
        MainView.outerBodyEvaluations += 1
        return lifecycleContent
    }

    /// 窗口装饰（工具栏、标题、焦点值）
    private var decoratedContent: some View {
        // 读取刷新令牌建立观察依赖：当前模型变化时这一层才会重绘（含窗口标题）
        let _ = reader.refreshToken
        return splitLayout
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbarContent }
            .navigationTitle(model.windowSubtitle)
            .navigationSubtitle(windowSubtitleSuffix)
            .focusedSceneValue(\.browserModel, model)
            .focusedSceneValue(\.tabCount, tabManager.count)
    }

    /// 生命周期与通知（单独修饰器，避免主表达式过长导致编译超时）
    private var lifecycleContent: some View {
        decoratedContent
        .onAppear {
            engine.scheduleCategoryCount()
            adopt(tabManager.activeTab)
            WindowBridge.shared.tabManager = tabManager
            TabDiagnostics.shared.record("startup.view",
                                         detail: "选择=\(String(describing: model.selection)) 布局=\(model.layout.rawValue)")
            // 注意：闭包不能捕获 `model`（那是本次求值的副本），
            // 必须每次从 TabManager 取当前模型，否则会写到过期的模型上。
            WindowBridge.shared.navigate = { target in
                WindowBridge.shared.tabManager?.activeModel.navigate(to: target)
            }

            // 后台扫描安卓设备（不阻塞界面，检测到后侧边栏自动出现入口）
            Task { await AndroidDeviceRegistry.shared.refresh() }

            guard !skipAutoNavigation else { return }
            let current = model
            if current.currentDirectory == nil, case .none = current.selection {
                current.navigate(to: .home)   // 与 Windows 一致：启动进入主页
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileBeginRename)) { _ in
            if let item = model.selectedItems.first { dialog = .rename(item) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileOpenFolder)) { _ in
            openFolderPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileGetInfo)) { _ in
            showInspector = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileShowHelp)) { _ in
            dialog = .help
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileNewTab)) { _ in
            TabDiagnostics.shared.record("MainView 收到新建页签通知")
            newTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileCloseTab)) { _ in
            TabDiagnostics.shared.record("MainView 收到关闭页签通知")
            closeCurrentTab()
        }

        .sheet(item: $dialog) { kind in
            switch kind {
            case .rename(let item):
                RenameSheet(item: item) { newName in model.rename(item, to: newName) }
            case .newFolder:
                TextInputSheet(titleKey: "dialog.newFolder.title", defaultText: NSLocalizedString("default.newFolderName", comment: "新建文件夹")) { name in
                    model.createFolder(named: name)
                }
            case .newFile:
                TextInputSheet(titleKey: "dialog.newFile.title", defaultText: "未命名.txt") { name in
                    model.createTextFile(named: name)
                }
            case .openWith(let item):
                OpenWithSheet(engine: engine, item: item) { appURL in
                    model.openSelection(withApplicationAt: appURL)
                }
            case .help:
                HelpSheet()
            }
        }
        .alert(NSLocalizedString("alert.error.title", comment: "操作未完成"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(NSLocalizedString("button.ok", comment: "好"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }


    // MARK: - 页签管理

    private func newTab(startDirectory: URL? = nil, activate: Bool = true) {
        tabManager.newTab(startDirectory: startDirectory, activate: activate)
        adopt(tabManager.activeTab)
    }

    private func closeTab(_ tab: WinFileTab) {
        tabManager.close(tab)
        adopt(tabManager.activeTab)
    }
    private func closeOtherTabs(keeping tab: WinFileTab) {
        tabManager.closeOthers(keeping: tab)
        adopt(tab)
    }
    private func selectTab(_ tab: WinFileTab) {
        TabDiagnostics.shared.record("selectTab", detail: "请求=\(tab.id.uuidString.prefix(4)) 当前=\(tabManager.activeTab.id.uuidString.prefix(4))")
        guard tab.id != tabManager.activeTab.id else {
            TabDiagnostics.shared.record("selectTab.skipped", detail: "已是活动页签")
            return
        }
        resetTransientState()
        tabManager.select(tab)
        adopt(tabManager.activeTab)
        syncSearchFieldFromModel()
        TabDiagnostics.shared.record("selectTab.done", detail: "现在=\(tabManager.activeTab.id.uuidString.prefix(4)) 数量=\(tabManager.count)")
    }

    /// 页签点击诊断（仅在 --selftest-tabs / 调试时输出）
    static func writeTabDiagnostics(to path: String) {
        TabDiagnostics.shared.write(to: path)
    }

    /// 切换页签时清理与上一页签有关的临时界面状态
    private func resetTransientState() {
        dialog = nil
        editingPath = false
        suggestions = []
        pathText = ""
    }

    /// 搜索框跟随当前页签的模型状态
    private func syncSearchFieldFromModel() {
        searchText = model.isSearching ? searchText : ""
        if !model.isSearching { searchText = "" }
    }
    private func closeCurrentTab() { tabManager.closeActive() }
    var tabCount: Int { tabManager.count }

    /// 页签栏（对应 Windows 资源管理器顶部的标签页条）
    /// 注意：这里刻意不使用 ScrollView —— 横向 ScrollView 会参与点击手势仲裁，
    /// 实测会导致页签点击无响应。页签数量有限，普通 HStack 足够。
    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                TabChipView(
                    tab: tab,
                    manager: tabManager,
                    onSelect: { selectTab(tab) },
                    onClose: { closeTab(tab) },
                    onCloseOthers: { closeOtherTabs(keeping: tab) },
                    onNew: { newTab() },
                    onDuplicate: { tabManager.duplicate(tab) }
                )
            }
            Button {
                TabDiagnostics.shared.record("tap.newTabButton")
                newTab()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("tab.new", "新标签页") + " (⌘T)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: - 命令栏

    private var commandBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button(NSLocalizedString("action.newFolder", comment: "新建文件夹")) { dialog = .newFolder }
                Button(NSLocalizedString("action.newFile", comment: "新建文本文档")) { dialog = .newFile }
                if model.clipboardHasText {
                    Divider()
                    Button(NSLocalizedString("action.pasteClipboardAsFile", comment: "把剪贴板文本存成文件")) {
                        _ = model.saveClipboardTextAsFile()
                    }
                }
            } label: {
                Label(NSLocalizedString("action.new", comment: "新建"), systemImage: "plus.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(NSLocalizedString("action.new", comment: "新建"))
            .disabled(model.currentDirectory == nil || model.isHomeView || model.isThisPCView)

            Divider().frame(height: 18)

            Button {
                model.cutSelectionToClipboard()
            } label: {
                Label(NSLocalizedString("action.cut", comment: "剪切"), systemImage: "scissors")
            }
            .help(NSLocalizedString("action.cut", comment: "剪切"))
            .disabled(model.selectedIDs.isEmpty)

            Button {
                model.copySelectionToClipboard()
            } label: {
                Label(NSLocalizedString("action.copy", comment: "复制"), systemImage: "doc.on.doc")
            }
            .help(NSLocalizedString("action.copy", comment: "复制"))
            .disabled(model.selectedIDs.isEmpty)

            Menu {
                Button(NSLocalizedString("action.copyPath", comment: "复制完整路径")) { model.copyPathToClipboard() }
                Button(NSLocalizedString("action.copyName", comment: "复制文件名")) { model.copyNameToClipboard() }
                Button(NSLocalizedString("action.copyDir", comment: "复制所在目录")) { model.copyPathToClipboard(includeDirectory: true) }
            } label: {
                Label(NSLocalizedString("action.copyAs", comment: "复制为"), systemImage: "link")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(NSLocalizedString("action.copyAs", comment: "复制为"))
            .disabled(model.selectedIDs.isEmpty)

            Button {
                model.paste()
            } label: {
                Label(NSLocalizedString("action.paste", comment: "粘贴"), systemImage: "clipboard")
            }
            .help(NSLocalizedString("action.paste", comment: "粘贴"))
            .disabled(model.clipboard == nil || model.currentDirectory == nil)

            Divider().frame(height: 18)

            Button {
                if let item = model.selectedItems.first { dialog = .rename(item) }
            } label: {
                Label(NSLocalizedString("action.rename", comment: "重命名"), systemImage: "pencil")
            }
            .help(NSLocalizedString("action.rename", comment: "重命名"))
            .disabled(model.selectedCount != 1)

            Button(role: .destructive) {
                confirmDelete()
            } label: {
                Label(NSLocalizedString("action.delete", comment: "删除"), systemImage: "trash")
            }
            .help(NSLocalizedString("action.moveToTrash", comment: "移到废纸篓"))
            .disabled(model.selectedIDs.isEmpty)

            Spacer()

            Picker("", selection: Binding(
                get: { model.sortField },
                set: { model.sortField = $0 }
            )) {
                ForEach(SortField.allCases, id: \.self) { field in
                    Text(field.localizedTitle).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button {
                model.sortAscendingFlag.toggle()
            } label: {
                Image(systemName: model.sortAscendingFlag ? "arrow.up" : "arrow.down")
            }
            .help(NSLocalizedString("action.toggleSortOrder", comment: "切换升序/降序"))

            Picker("", selection: Binding(
                get: { model.layout },
                set: { model.setLayout($0) }
            )) {
                Image(systemName: "list.bullet").tag(ViewLayout.details)
                Image(systemName: "square.grid.2x2").tag(ViewLayout.icons)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)

            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help(NSLocalizedString("action.toggleInspector", comment: "显示详细信息"))
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)          // 图标按钮，避免中文标签被挤压裁剪
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: - 地址栏

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!model.canGoBack)
                Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!model.canGoForward)
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(!model.canGoUp)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)

            // 独立视图直接观察模型：路径变化即重绘（计算属性做不到这点）
            PathBarHost(
                engine: engine,
                model: model,
                editingPath: $editingPath,
                pathText: $pathText,
                suggestions: suggestions,
                onCommitPath: commitPath,
                onTextChange: { value in
                    pathText = value
                    refreshSuggestions(for: value)
                },
                onAcceptSuggestion: { suggestion, descend in
                    pathText = descend && suggestion.isDirectory ? suggestion.path + "/" : suggestion.path
                    refreshSuggestions(for: pathText)
                },
                onCancelEdit: {
                    editingPath = false
                    suggestions = []
                },
                onBeginEditing: beginEditingPath
            )

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("search.placeholder", comment: "搜索"), text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { model.search(searchText) }
                    .onChange(of: searchText) { newValue in
                        if newValue.isEmpty { model.clearSearch() }
                    }
                if model.isSearching {
                    Button {
                        searchText = ""
                        model.clearSearch()
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .frame(width: 240)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func beginEditingPath() {
        guard let dir = model.currentDirectory else { return }
        pathText = dir.path
        editingPath = true
        pathFieldFocused = true
        refreshSuggestions(for: pathText)
    }

    private func commitPath() {
        let trimmed = pathText.trimmingCharacters(in: .whitespaces)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { editingPath = false; return }
        let url = URL(fileURLWithPath: expanded)
        editingPath = false
        suggestions = []
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            model.selectFolder(url)
        } else {
            model.selectFolder(url.deletingLastPathComponent())
        }
    }

    private func refreshSuggestions(for text: String) {
        let expanded = (text as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded.isEmpty ? NSHomeDirectory() : expanded)
        let parent = expanded.hasSuffix("/") ? url : url.deletingLastPathComponent()
        let prefix = expanded.hasSuffix("/") ? "" : url.lastPathComponent.lowercased()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { suggestions = []; return }
        suggestions = entries
            .filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix) }
            .prefix(12)
            .compactMap { candidate in
                let isDir = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return PathSuggestion(path: candidate.path, name: candidate.lastPathComponent, isDirectory: isDir)
            }
    }

    // MARK: - 内容区

    private var contentArea: some View {
        // 内容区必须自行观察模型：MainView 这一层不随模型变化重绘，
        // 否则文件列表会一直绑在旧模型上（表现为"点了跳转，要切页签才看到"）
        TabContentHost(
            engine: engine,
            reader: reader,
            dialog: $dialog,
            openFolderPanel: { openFolderPanel(newTab: true) }
        )
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 左侧只保留「打开文件夹」。
        // 「新标签页」按钮已按要求移除，其入口仍有：⌘T 或页签栏右侧的「+」。
        ToolbarItemGroup(placement: .navigation) {
            // 打开文件夹（保留）：在新页签中打开，不影响当前页签
            Button { openFolderPanel(newTab: true) } label: {
                Label(L("action.openFolderInNewTab", "打开文件夹"),
                      systemImage: "folder.badge.plus")
            }
            .help(L("action.openFolder.help", "选择文件夹并打开（在新页签中）"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.openSelection() } label: {
                Label(NSLocalizedString("action.open", comment: "打开"), systemImage: "arrow.up.forward.app")
            }
            .disabled(model.selectedIDs.isEmpty)

            Button { model.revealSelection() } label: {
                Label(NSLocalizedString("action.reveal", comment: "在访达中显示"), systemImage: "magnifyingglass")
            }
            .disabled(model.selectedIDs.isEmpty)

            Button {
                if let item = model.selectedItems.first { dialog = .openWith(item) }
            } label: {
                Label(NSLocalizedString("action.openWith", comment: "打开方式"), systemImage: "square.grid.2x2.fill")
            }
            .disabled(model.selectedCount != 1)
        }
    }

    // MARK: - 授权文件夹 / 删除确认

    /// 选择文件夹：
    /// - 非沙盒：直接作为新页签打开
    /// 选择文件夹并在新页签中打开（本地版可直接访问，无授权概念）
    private func openFolderPanel(newTab inNewTab: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = inNewTab
        panel.prompt = L("panel.open", "打开")
        panel.message = L("panel.open.message", "选择要打开的文件夹")
        panel.directoryURL = FileSystemService.realHomeDirectory()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let targets = panel.urls
        if inNewTab {
            // 每个选中的文件夹各开一个页签，首个直接激活
            for (index, url) in targets.enumerated() {
                newTab(startDirectory: url, activate: index == 0)
            }
        } else if let first = targets.first {
            model.selectFolder(first)
        }
    }

    private func confirmDelete() {
        let count = model.selectedCount
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = count == 1
            ? String(format: NSLocalizedString("alert.delete.title", comment: "删除项目"), model.selectedItems.first?.name ?? "")
            : String(format: NSLocalizedString("alert.delete.title.multiple", comment: "删除多个项目"), count)
        alert.informativeText = NSLocalizedString("alert.delete.message", comment: "项目将移到废纸篓，可从废纸篓恢复。")
        alert.addButton(withTitle: NSLocalizedString("action.delete", comment: "移到废纸篓"))
        alert.addButton(withTitle: NSLocalizedString("button.cancel", comment: "取消"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteSelection()
        }
    }
}

// MARK: - 对话框类型

enum DialogKind: Identifiable {
    case rename(FileItem)
    case newFolder
    case newFile
    case openWith(FileItem)
    case help

    var id: String {
        switch self {
        case .rename(let item): return "rename-\(item.id)"
        case .newFolder: return "newFolder"
        case .newFile: return "newFile"
        case .openWith(let item): return "openWith-\(item.id)"
        case .help: return "help"
        }
    }
}

struct PathSuggestion: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    var id: String { path }
}

// MARK: - 状态栏

struct StatusBarView: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.statusMessage)
            // 计数统一用 selectedItems（与检查器一致）。
            // 若这里用 selectedIDs，会与检查器出现不同数字：
            // Table 自身维护一套高亮状态，程序化改选时两者可能短暂不一致。
            if !model.selectedItems.isEmpty {
                Divider().frame(height: 12)
                Text(String(format: NSLocalizedString("status.selected", comment: "已选择"), model.selectedItems.count))
                if !model.selectionSummary.isEmpty {
                    Text(model.selectionSummary)
                }
            }
            Spacer()
            if let dir = model.currentDirectory, let info = model.volumeInfo(for: dir) {
                Text(String(format: NSLocalizedString("status.volume", comment: "磁盘空间"), info.free, info.total))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    let openPanel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)

            if model.isLoadingCategory {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString("empty.categoryLoading", comment: "正在归类提示"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                if !model.isCategoryView {
                    Button(NSLocalizedString("action.toggleHidden", comment: "显示/隐藏隐藏文件")) {
                        model.toggleHiddenFiles()
                    }
                }
            }
        }
        .padding(40)
    }

    private var iconName: String {
        if model.isLoadingCategory { return "hourglass" }
        if model.isSearching { return "magnifyingglass" }
        if model.isCategoryView { return model.categoryFilter?.symbol ?? "square.grid.2x2" }
        return "folder"
    }

    private var title: String {
        if model.isSearching { return NSLocalizedString("empty.noSearchResult", comment: "没有匹配的项目") }
        if model.isCategoryView {
            return model.isLoadingCategory
                ? NSLocalizedString("status.categoryLoading", comment: "正在归类")
                : NSLocalizedString("empty.category", comment: "该分类下没有文件")
        }
        return NSLocalizedString("empty.folder", comment: "此文件夹为空")
    }

    private var hint: String {
        if model.isCategoryView {
            return String(format: NSLocalizedString("empty.category.hint", comment: "分类为空说明"),
                          model.categoryFilter?.localizedName ?? "")
        }
        return NSLocalizedString("empty.folder.hint", comment: "空文件夹说明")
    }
}

// MARK: - 单个页签

/// 一个页签按钮。
///
/// 关键：本视图用 `@ObservedObject` **直接持有 TabManager**，
/// 因此高亮状态由页签自身驱动 —— 不依赖父视图是否重绘。
/// （此前挂在 MainView 上，那一层在切页签时不再重绘，导致高亮不跟手。）
struct TabChipView: View {
    let tab: WinFileTab
    @ObservedObject var manager: TabManager
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onNew: () -> Void
    let onDuplicate: () -> Void

    private var isActive: Bool { manager.activeTab.id == tab.id }

    private func logChipRender() -> Bool {
        TabDiagnostics.shared.record("chip", detail: "页签=\(tab.title) 高亮=\(isActive)")
        return true
    }

    var body: some View {
        // 每次求值记录高亮状态：用于确认"切换后页签确实以正确状态重绘了"
        let _ = logChipRender()
        // 上报自身位置：供自动化精确点击（避免猜坐标导致误判）
        let _ = WindowBridge.shared.registerChip(id: tab.id, title: tab.title)
        Button {
            TabDiagnostics.shared.record("tap", detail: "tab=\(tab.title) id=\(tab.id.uuidString.prefix(4))")
            onSelect()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(tab.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .opacity(isActive || manager.count > 1 ? 0.7 : 0)
                .help(L("tab.close", "关闭标签页"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1)
            )
            // 选中态再加一条底部高亮，切换时更醒目
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L("tab.close", "关闭标签页")) { onClose() }
            Button(L("tab.closeOthers", "关闭其它标签页")) { onCloseOthers() }
                .disabled(manager.count <= 1)
            Divider()
            Button(L("tab.new", "新标签页")) { onNew() }
            Button(L("tab.duplicate", "复制标签页")) { onDuplicate() }
        }
        .help(tab.pathDescription)
        .background(
            TabChipFrameReporter(id: tab.id)
                .allowsHitTesting(false)
        )
    }
}

/// 上报页签在窗口中的位置（供自动化精确点击）
struct TabChipFrameReporter: NSViewRepresentable {
    let id: UUID

    func makeNSView(context: Context) -> NSView {
        let view = ReporterView()
        view.id = id
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ReporterView)?.id = id
    }

    final class ReporterView: NSView {
        var id: UUID = UUID()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 布局完成后再取位置，否则可能拿到零尺寸
            DispatchQueue.main.async { [weak self] in self?.report() }
        }
        override func layout() {
            super.layout()
            report()
        }
        private func report() {
            guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
            let rect = convert(bounds, to: nil)
            WindowBridge.shared.setChipFrame(id: id, frame: rect)
        }
    }
}
