// 主界面：侧边栏 + 命令栏 + 地址栏（面包屑/补全）+ 文件列表 + 详细信息窗格
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    /// 自动化渲染（截图/测试）时置为 true，跳过 onAppear 的自动导航，避免覆盖预设状态
    var skipAutoNavigation: Bool = false
    /// 页签管理（一个窗口内可开多个页签）
    @StateObject private var tabManager: TabManager
    @State private var showSidebar = true
    @State private var showInspector = true
    @AppStorage(PaneLayout.sidebarKey) private var sidebarWidth = 216.0
    @AppStorage(PaneLayout.inspectorKey) private var inspectorWidth = 264.0
    @State private var dialog: DialogKind?
    @ObservedObject private var operationHistory = FileOperationHistory.shared
    @State private var pathText = ""
    @State private var suggestions: [PathSuggestion] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var editingPath = false
    @State private var searchText = ""
    @FocusState private var pathFieldFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var draggingTabID: UUID?
    @State private var dragTargetID: UUID?

    /// 兼容旧测试入口
    static var currentTabManager: TabManager? { WindowBridge.shared.tabManager }
    /// 外层视图（承载标题/命令栏/地址栏）的求值次数，供验证刷新是否发生
    static var outerBodyEvaluations = 0

    init(engine: FSEngine, skipAutoNavigation: Bool = false, existingManager: TabManager? = nil) {
        self.engine = engine
        self.skipAutoNavigation = skipAutoNavigation
        let start: URL? = UserDefaults.standard.string(forKey: "StartFolderPath").flatMap { path in
            guard !path.isEmpty else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }
        let manager = existingManager ?? TabManager(engine: engine, startDirectory: start, restoreSession: !skipAutoNavigation && !CommandLine.arguments.contains("--selftest-tabs") && !CommandLine.arguments.contains("--run-tests"))
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
        GeometryReader { geometry in
            let inspectorAvailable = !model.isWeChatCleanupView && !model.isStorageCleanupView
            let inspectorVisible = showInspector && inspectorAvailable
            let collapsedRails = (showSidebar ? 0 : 1) + (inspectorAvailable && !showInspector ? 1 : 0)
            let paneBudget = max(0, geometry.size.width - CGFloat(collapsedRails) * PaneLayout.divider)
            let widths = PaneLayout.widths(total: paneBudget, sidebar: sidebarWidth,
                                           inspector: inspectorWidth, showsInspector: inspectorVisible,
                                           showsSidebar: showSidebar)
            HStack(spacing: 0) {
                if showSidebar {
                    SidebarView(engine: engine, model: model).frame(width: widths.sidebar)
                    PaneResizeHandle(preferredWidth: $sidebarWidth, actualWidth: widths.sidebar, range: 160...360,
                                     expandsToRight: true, title: L("layout.sidebarWidth", "侧边栏宽度"), defaultWidth: 216,
                                     collapseTitle: L("action.hideSidebar", "隐藏侧边栏"), collapse: { showSidebar = false })
                } else {
                    CollapsedPaneHandle(expandsToRight: true, title: L("action.showSidebar", "显示侧边栏"),
                                        expand: { showSidebar = true })
                }
                contentPane
                if inspectorVisible {
                    PaneResizeHandle(preferredWidth: $inspectorWidth, actualWidth: widths.inspector, range: 200...420,
                                     expandsToRight: false, title: L("layout.inspectorWidth", "详细信息宽度"), defaultWidth: 264,
                                     collapseTitle: L("action.hideInspector", "隐藏详细信息"), collapse: { showInspector = false })
                    InspectorView(engine: engine, model: model).frame(width: widths.inspector)
                } else if inspectorAvailable {
                    CollapsedPaneHandle(expandsToRight: false, title: L("action.toggleInspector", "显示详细信息"),
                                        expand: { showInspector = true })
                }
            }
        }
    }

    private var contentPane: some View {
        VStack(spacing: 0) {
            tabStrip
            if !model.isStorageCleanupView && !model.isWeChatCleanupView {
                commandBar
            }
            addressBar
            Divider().opacity(0.6)
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .focusedSceneValue(\.canRestoreTab, !tabManager.closedTabs.isEmpty)
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
            if !CommandLine.arguments.contains("--skip-device-tests") {
                AndroidDeviceRegistry.shared.startMonitoring()
            }

            guard !skipAutoNavigation else { return }
            let current = model
            if current.currentDirectory == nil, case .none = current.selection {
                current.navigate(to: .home)   // 与 Windows 一致：启动进入主页
            }
        }
        .onReceive(operationHistory.$errorMessage.compactMap { $0 }) { error in
            model.errorMessage = error
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileBeginRename)) { notification in
            guard (notification.object as? TabManager ?? BrowserWindowCommands.shared.manager) === tabManager else { return }
            if model.selectedCount > 1, !model.isAndroidPath { dialog = .batchRename(model.selectedItems) }
            else if let item = model.selectedItems.first { dialog = .rename(item) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileOpenFolder)) { notification in
            guard (notification.object as? TabManager ?? BrowserWindowCommands.shared.manager) === tabManager else { return }
            openFolderPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileSearch)) { notification in
            guard let manager = notification.object as? TabManager, manager === tabManager else { return }
            dialog = .advancedSearch
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileGetInfo)) { notification in
            guard (notification.object as? TabManager ?? BrowserWindowCommands.shared.manager) === tabManager else { return }
            if model.isWeChatCleanupView { dialog = .getInfo } else { showInspector = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileShowHelp)) { notification in
            guard (notification.object as? TabManager ?? BrowserWindowCommands.shared.manager) === tabManager else { return }
            dialog = .help
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileNewTab)) { notification in
            guard (notification.object as? TabManager ?? BrowserWindowCommands.shared.manager) === tabManager else { return }
            TabDiagnostics.shared.record("MainView 收到新建页签通知")
            newTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .winFileCloseTab)) { notification in
            guard (notification.object as? TabManager ?? BrowserWindowCommands.shared.manager) === tabManager else { return }
            TabDiagnostics.shared.record("MainView 收到关闭页签通知")
            closeCurrentTab()
        }

        .sheet(item: $dialog) { kind in
            switch kind {
            case .batchRename(let items):
                BatchRenameSheet(model: model, items: items)
            case .openFolder:
                FolderPickerSheet(initialDirectory: model.currentDirectory?.isFileURL == true ? model.currentDirectory : nil, onOpen: { urls in
                    DispatchQueue.main.async {
                        for (index, url) in urls.enumerated() {
                            newTab(startDirectory: url, activate: index == 0)
                        }
                    }
                })
            case .advancedSearch:
                AdvancedSearchSheet(model: model, initialQuery: searchText)
            case .duplicates:
                DuplicateFilesSheet(model: model)
            case .rename(let item):
                RenameSheet(item: item) { newName in model.rename(item, to: newName) }
            case .newFolder:
                TextInputSheet(titleKey: "dialog.newFolder.title", defaultText: WLocalizedString("default.newFolderName", comment: "新建文件夹")) { name in
                    model.createFolder(named: name)
                }
            case .newFile:
                TextInputSheet(titleKey: "dialog.newFile.title", defaultText: L("default.newFileName", "未命名.txt")) { name in
                    model.createTextFile(named: name)
                }
            case .openWith(let item):
                OpenWithSheet(engine: engine, item: item,
                              onPick: { appURL in
                                  model.openSelection(withApplicationAt: appURL)
                              },
                              onSetDefault: { app in
                                  model.setDefaultApplication(app, for: item)
                              })
            case .getInfo:
                VStack(spacing: 0) {
                    InspectorView(engine: engine, model: model)
                    HStack {
                        Spacer()
                        Button(L("button.ok", "好")) { dialog = nil }.keyboardShortcut(.defaultAction)
                    }.padding()
                }.frame(width: 360, height: 500)
            case .help:
                HelpSheet()
            }
        }
        .sheet(item: Binding(get: { model.archivePreviewRequest }, set: { model.archivePreviewRequest = $0 })) { request in
            ArchivePreviewSheet(request: request, browser: model)
        }
        .sheet(item: Binding(get: { model.folderPickerRequest }, set: { model.folderPickerRequest = $0 })) { request in
            FolderPickerSheet(initialDirectory: request.initialDirectory, title: request.title) { url in
                DispatchQueue.main.async { request.onSelect(url) }
                return nil
            }
        }
        .alert(WLocalizedString("alert.error.title", comment: "操作未完成"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(WLocalizedString("button.ok", comment: "好"), role: .cancel) { model.errorMessage = nil }
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
        if let store = model.activeStorageCleanup { searchText = store.search }
        else { searchText = model.isWeChatCleanupView ? model.weChatCleanup.search : model.searchQuery }
    }
    private func closeCurrentTab() { tabManager.closeActive() }
    var tabCount: Int { tabManager.count }

    /// 页签栏（对应 Windows 资源管理器顶部的标签页条）
    /// 注意：这里刻意不使用 ScrollView —— 横向 ScrollView 会参与点击手势仲裁，
    /// 实测会导致页签点击无响应。页签数量有限，普通 HStack 足够。
    private var tabStrip: some View {
        GeometryReader { geometry in
            let visible = tabManager.visibleTabs(width: geometry.size.width)
            HStack(spacing: 4) {
                ForEach(visible) { tab in
                    TabChipView(tab: tab, manager: tabManager,
                                onSelect: { selectTab(tab) }, onClose: { closeTab(tab) },
                                onCloseOthers: { closeOtherTabs(keeping: tab) }, onNew: { newTab() },
                                onDuplicate: { tabManager.duplicate(tab) },
                                onDetach: {
                                    if let id = BrowserWindowCommands.shared.prepareDetachedWindow(from: tabManager, tab: tab, engine: engine) {
                                        openWindow(value: id)
                                    }
                                },
                                onMerge: { BrowserWindowCommands.shared.mergeOtherWindows(into: tabManager) },
                                isDropTargeted: dragTargetID == tab.id)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: TabFramePreferenceKey.self,
                                value: [tab.id: proxy.frame(in: .named("tabStrip"))])
                        })
                        .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("tabStrip"))
                            .onChanged { value in
                                draggingTabID = tab.id
                                dragTargetID = tabFrames.first { $0.value.contains(value.location) && $0.key != tab.id }?.key
                            }
                            .onEnded { value in
                                if draggingTabID == tab.id,
                                   let target = tabFrames.first(where: { $0.value.contains(value.location) && $0.key != tab.id })?.key {
                                    tabManager.moveTab(tab.id, over: target)
                                }
                                draggingTabID = nil
                                dragTargetID = nil
                            })
                        .frame(maxWidth: 200)
                }
                Button { newTab() } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).help(L("tab.new", "新标签页") + " (⌘T)")
                Menu {
                    ForEach(tabs) { tab in
                        Button { selectTab(tab) } label: {
                            Label((tab.isPinned ? "📌 " : "") + tab.title, systemImage: tab.id == activeTab.id ? "checkmark" : tab.symbol)
                        }
                    }
                    Divider()
                    Button(activeTab.isPinned ? L("tab.unpin", "取消固定标签页") : L("tab.pin", "固定标签页")) { tabManager.togglePin(activeTab) }
                    Button(L("tab.restore", "恢复关闭的标签页")) { tabManager.restoreClosedTab() }
                        .disabled(tabManager.closedTabs.isEmpty)
                } label: { Image(systemName: "chevron.down").frame(width: 20, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("tab.all", "所有标签页（%d）", tabs.count))
                .accessibilityLabel(L("tab.all", "所有标签页（%d）", tabs.count))
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.vertical, 5)
                .coordinateSpace(name: "tabStrip")
                .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
        }.frame(height: 36).background(InterfaceStyle.chrome).background(BrowserInteractionBoundary())
    }

    // MARK: - 命令栏

    private var commandBar: some View {
        HStack(spacing: 8) {
            if model.supportsDirectoryCreation {
                Menu {
                    Button(WLocalizedString("action.newFolder", comment: "新建文件夹")) { dialog = .newFolder }
                    Button(WLocalizedString("action.newFile", comment: "新建文本文档")) { dialog = .newFile }
                    if model.clipboardHasText {
                        Divider()
                        Button(WLocalizedString("action.pasteClipboardAsFile", comment: "把剪贴板文本存成文件")) {
                            _ = model.saveClipboardTextAsFile()
                        }
                    }
                } label: {
                    Label(WLocalizedString("action.new", comment: "新建"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .help(WLocalizedString("action.new", comment: "新建"))
                .disabled(!model.canMutateFiles)

                Divider().frame(height: 18)
            }

            Button {
                model.cutSelectionToClipboard()
            } label: {
                Label(WLocalizedString("action.cut", comment: "剪切"), systemImage: "scissors")
            }
            .help(WLocalizedString("action.cut", comment: "剪切"))
            .disabled(model.selectedIDs.isEmpty)

            Button {
                model.copySelectionToClipboard()
            } label: {
                Label(WLocalizedString("action.copy", comment: "复制"), systemImage: "doc.on.doc")
            }
            .help(WLocalizedString("action.copy", comment: "复制"))
            .disabled(model.selectedIDs.isEmpty)

            Menu {
                Button(WLocalizedString("action.copyPath", comment: "复制完整路径")) { model.copyPathToClipboard() }
                Button(WLocalizedString("action.copyName", comment: "复制文件名")) { model.copyNameToClipboard() }
                Button(WLocalizedString("action.copyDir", comment: "复制所在目录")) { model.copyPathToClipboard(includeDirectory: true) }
            } label: {
                Label(WLocalizedString("action.copyAs", comment: "复制为"), systemImage: "link")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(WLocalizedString("action.copyAs", comment: "复制为"))
            .disabled(model.selectedIDs.isEmpty)

            if model.supportsDirectoryCreation {
                Button {
                    model.paste()
                } label: {
                    Label(WLocalizedString("action.paste", comment: "粘贴"), systemImage: "clipboard")
                }
                .help(WLocalizedString("action.paste", comment: "粘贴"))
                .disabled(!model.canPaste)
            }

            Divider().frame(height: 18)

            Button {
                if model.selectedCount > 1, !model.isAndroidPath { dialog = .batchRename(model.selectedItems) }
                else if let item = model.selectedItems.first { dialog = .rename(item) }
            } label: {
                Label(WLocalizedString("action.rename", comment: "重命名"), systemImage: "pencil")
            }
            .help(WLocalizedString("action.rename", comment: "重命名"))
            .disabled(model.selectedCount == 0 || (model.isAndroidPath && model.selectedCount != 1) || !model.canMutateFiles)

            Button(role: .destructive) {
                confirmDelete()
            } label: {
                Label(WLocalizedString("action.delete", comment: "删除"), systemImage: "trash")
            }
            .help(model.deleteActionTitle)
            .disabled(model.selectedIDs.isEmpty)

            Spacer()

            if !model.isAndroidPath {
                Menu {
                    Button(L("rename.batch", "批量重命名")) { dialog = .batchRename(model.selectedItems) }
                        .disabled(model.selectedCount < 2 || !model.canMutateFiles)
                    if model.supportsDirectorySearch {
                        Button(L("search.advanced", "组合搜索")) { dialog = .advancedSearch }
                    }
                    Button(L("duplicates.title", "查找重复文件")) { dialog = .duplicates }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("organize.tools", "文件整理工具"))
                .accessibilityLabel(L("organize.tools", "文件整理工具"))
            }

            if model.showsFileList {
                Divider().frame(height: 18)
                ViewThatFits(in: .horizontal) {
                    presentationControls
                    Menu {
                        presentationMenu
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("layout.options", "显示与排序"))
                }.frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .buttonStyle(LeafToolbarButtonStyle())
        .labelStyle(.iconOnly)          // 图标按钮，避免中文标签被挤压裁剪
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .controlSize(.regular)
        .background(InterfaceStyle.chrome)
    }

    private var presentationControls: some View {
        HStack(spacing: 8) {
            Picker(L("wechat.sort", "排序"), selection: Binding(get: { model.sortField }, set: { model.sortField = $0 })) {
                ForEach(SortField.allCases, id: \.self) { field in Text(field.localizedTitle).tag(field) }
            }.labelsHidden().frame(width: 110)
            Button { model.sortAscendingFlag.toggle() } label: {
                Image(systemName: model.sortAscendingFlag ? "arrow.up" : "arrow.down")
            }.help(WLocalizedString("action.toggleSortOrder", comment: "切换升序/降序"))
            Picker(L("layout.options", "显示与排序"), selection: Binding(get: { model.layout }, set: { model.setLayout($0) })) {
                Image(systemName: "list.bullet").tag(ViewLayout.details)
                Image(systemName: "square.grid.2x2").tag(ViewLayout.icons)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 84)
        }
    }

    @ViewBuilder
    private var presentationMenu: some View {
        Picker(L("wechat.sort", "排序"), selection: Binding(get: { model.sortField }, set: { model.sortField = $0 })) {
            ForEach(SortField.allCases, id: \.self) { field in Text(field.localizedTitle).tag(field) }
        }
        Toggle(L("sort.ascending", "升序"), isOn: Binding(get: { model.sortAscendingFlag }, set: { model.sortAscendingFlag = $0 }))
        Divider()
        Button(L("layout.details", "详细信息")) { model.setLayout(.details) }
        Button(L("layout.icons", "大图标")) { model.setLayout(.icons) }
        Toggle(WLocalizedString("action.toggleInspector", comment: "显示详细信息"), isOn: $showInspector)
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

            if model.supportsDirectorySearch {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(WLocalizedString("search.placeholder", comment: "搜索"), text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { dialog = .advancedSearch }
                        .onChange(of: searchText) { newValue in
                            if newValue.isEmpty && !model.searchCriteria.isActive { model.clearSearch() }
                        }
                    if model.isSearching {
                        Button {
                            searchText = ""
                            model.searchCriteria = FileSearchCriteria()
                            model.clearSearch()
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .frame(minWidth: 120, idealWidth: 200, maxWidth: 240)
                Button { dialog = .advancedSearch } label: {
                    Image(systemName: model.searchCriteria.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }.buttonStyle(.borderless).help(L("search.advanced", "组合搜索"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(InterfaceStyle.chrome)
    }

    private func beginEditingPath() {
        guard let dir = model.currentDirectory else { return }
        pathText = dir.path
        editingPath = true
        pathFieldFocused = true
        refreshSuggestions(for: pathText)
    }

    private func commitPath() {
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { editingPath = false; return }
        editingPath = false
        suggestionTask?.cancel()
        suggestions = []
        model.openPath(trimmed)
    }

    private func refreshSuggestions(for text: String) {
        suggestionTask?.cancel()
        let base = model.currentDirectory?.isFileURL == true ? model.currentDirectory! : FileSystemService.realHomeDirectory()
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { () -> [PathSuggestion] in
                guard let url = FolderPickerModel.resolvePath(text, relativeTo: base) else { return [] }
                let parent = text.hasSuffix("/") ? url : url.deletingLastPathComponent()
                let prefix = text.hasSuffix("/") ? "" : url.lastPathComponent.lowercased()
                guard let entries = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
                return entries.filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    .prefix(12).map { candidate in
                        PathSuggestion(path: candidate.path, name: candidate.lastPathComponent,
                                       isDirectory: (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                    }
            }.value
            guard !Task.isCancelled, editingPath, pathText == text else { return }
            suggestions = found
        }
    }

    // MARK: - 内容区

    private var contentArea: some View {
        // 内容区必须自行观察模型：MainView 这一层不随模型变化重绘，
        // 否则文件列表会一直绑在旧模型上（表现为"点了跳转，要切页签才看到"）
        CachedTabContent(
            engine: engine,
            manager: tabManager,
            tab: activeTab,
            tabs: tabs,
            dialog: $dialog,
            openFolderPanel: { openFolderPanel() }
        )
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showSidebar.toggle() } label: {
                Label(showSidebar ? L("action.hideSidebar", "隐藏侧边栏") : L("action.showSidebar", "显示侧边栏"),
                      systemImage: "sidebar.left")
            }
            .help(showSidebar ? L("action.hideSidebar", "隐藏侧边栏") : L("action.showSidebar", "显示侧边栏"))
            .accessibilityIdentifier("sidebar.toggle")
            // 打开文件夹（保留）：在新页签中打开，不影响当前页签
            Button { openFolderPanel() } label: {
                Label(L("action.openFolderInNewTab", "打开文件夹"),
                      systemImage: "folder.badge.plus")
            }
            .help(L("action.openFolder.help", "选择文件夹并打开（在新页签中）"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { dialog = .advancedSearch } label: {
                // 放大镜是「搜索」的通用语义，工具栏上只保留这一处使用它
                Label(L("search.windowTitle", "搜索文件"), systemImage: "magnifyingglass")
            }
            .help(L("search.windowTitle", "搜索文件") + " (⌘F)")
            .accessibilityIdentifier("search.open")
            if !model.isWeChatCleanupView && !model.isStorageCleanupView {
                Button { showInspector.toggle() } label: {
                    Label(WLocalizedString("action.toggleInspector", comment: "显示详细信息"),
                          systemImage: "sidebar.right")
                }
                .help(WLocalizedString("action.toggleInspector", comment: "显示详细信息"))
                .accessibilityIdentifier("inspector.toggle")
            }
        }
    }

    // MARK: - 授权文件夹 / 删除确认

    /// 选择文件夹：
    /// - 非沙盒：直接作为新页签打开
    /// 选择文件夹并在新页签中打开（本地版可直接访问，无授权概念）
    private func openFolderPanel() {
        dialog = .openFolder
    }

    private func confirmDelete() {
        if model.isWeChatCleanupView || model.isStorageCleanupView || model.isAndroidPath { model.deleteSelection(); return }
        let count = model.selectedCount
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = count == 1
            ? String(format: WLocalizedString("alert.delete.title", comment: "删除项目"), model.selectedItems.first?.name ?? "")
            : String(format: WLocalizedString("alert.delete.title.multiple", comment: "删除多个项目"), count)
        alert.informativeText = WLocalizedString("alert.delete.message", comment: "项目将移到废纸篓，可从废纸篓恢复。")
        alert.addButton(withTitle: WLocalizedString("action.delete", comment: "移到废纸篓"))
        alert.addButton(withTitle: WLocalizedString("button.cancel", comment: "取消"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteSelection()
        }
    }
}

// MARK: - 对话框类型

enum DialogKind: Identifiable {
    case batchRename([FileItem])
    case advancedSearch
    case openFolder
    case duplicates
    case rename(FileItem)
    case newFolder
    case newFile
    case openWith(FileItem)
    case help
    case getInfo

    var id: String {
        switch self {
        case .batchRename: return "batchRename"
        case .openFolder: return "openFolder"
        case .advancedSearch: return "advancedSearch"
        case .duplicates: return "duplicates"
        case .rename(let item): return "rename-\(item.id)"
        case .newFolder: return "newFolder"
        case .newFile: return "newFile"
        case .openWith(let item): return "openWith-\(item.id)"
        case .help: return "help"
        case .getInfo: return "getInfo"
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
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.statusMessage).lineLimit(1).truncationMode(.middle).help(model.statusMessage)
            // 计数统一用 selectedItems（与检查器一致）。
            // 若这里用 selectedIDs，会与检查器出现不同数字：
            // Table 自身维护一套高亮状态，程序化改选时两者可能短暂不一致。
            if !model.selectedItems.isEmpty {
                Divider().frame(height: 12)
                Text(String(format: WLocalizedString("status.selected", comment: "已选择"), model.selectedItems.count))
                if !model.selectionSummary.isEmpty {
                    Text(model.selectionSummary)
                }
            }
            Spacer()
            if let dir = model.currentDirectory, let info = model.volumeInfo(for: dir) {
                Text(String(format: WLocalizedString("status.volume", comment: "磁盘空间"), info.free, info.total))
            }
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(InterfaceStyle.chrome)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    @ObservedObject private var localization = Localization.shared
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
                    Text(WLocalizedString("empty.categoryLoading", comment: "正在归类提示"))
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
                    Button(WLocalizedString("action.toggleHidden", comment: "显示/隐藏隐藏文件")) {
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
        if model.isSearching { return WLocalizedString("empty.noSearchResult", comment: "没有匹配的项目") }
        if model.isCategoryView {
            return model.isLoadingCategory
                ? WLocalizedString("status.categoryLoading", comment: "正在归类")
                : WLocalizedString("empty.category", comment: "该分类下没有文件")
        }
        return WLocalizedString("empty.folder", comment: "此文件夹为空")
    }

    private var hint: String {
        if model.isCategoryView {
            return String(format: WLocalizedString("empty.category.hint", comment: "分类为空说明"),
                          model.categoryFilter?.localizedName ?? "")
        }
        return WLocalizedString("empty.folder.hint", comment: "空文件夹说明")
    }
}

// MARK: - 单个页签

/// 一个页签按钮。
///
/// 关键：本视图用 `@ObservedObject` **直接持有 TabManager**，
/// 因此高亮状态由页签自身驱动 —— 不依赖父视图是否重绘。
/// （此前挂在 MainView 上，那一层在切页签时不再重绘，导致高亮不跟手。）
struct TabChipView: View {
    @ObservedObject private var localization = Localization.shared
    let tab: WinFileTab
    @ObservedObject var manager: TabManager
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onNew: () -> Void
    let onDuplicate: () -> Void
    let onDetach: () -> Void
    let onMerge: () -> Void
    let isDropTargeted: Bool

    private var isActive: Bool { manager.activeTab.id == tab.id }

    private func logChipRender() -> Bool {
        if TabDiagnostics.recordsViewRendering {
            TabDiagnostics.shared.record("chip", detail: "页签=\(tab.title) 高亮=\(isActive)")
        }
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
                if !tab.isPinned {
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
                } else { Image(systemName: "pin.fill").font(.caption2) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? InterfaceStyle.surface : Color.clear)
            )
            // A single accent marks the active tab; keyboard focus remains native.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button(tab.isPinned ? L("tab.unpin", "取消固定标签页") : L("tab.pin", "固定标签页")) { manager.togglePin(tab) }
            Button(L("tab.moveLeft", "向左移动标签页")) { manager.moveTab(tab, direction: -1) }
                .disabled(!manager.canMoveTab(tab, direction: -1))
            Button(L("tab.moveRight", "向右移动标签页")) { manager.moveTab(tab, direction: 1) }
                .disabled(!manager.canMoveTab(tab, direction: 1))
            Divider()
            Button(L("tab.detach", "移到新窗口")) { onDetach() }.disabled(manager.count <= 1)
            Button(L("tab.mergeWindows", "合并所有窗口")) { onMerge() }
                .disabled(!BrowserWindowCommands.shared.hasOtherWindows)
            Divider()
            Button(L("tab.close", "关闭标签页")) { onClose() }.disabled(tab.isPinned)
            Button(L("tab.restore", "恢复关闭的标签页")) { manager.restoreClosedTab() }.disabled(manager.closedTabs.isEmpty)
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

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
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
