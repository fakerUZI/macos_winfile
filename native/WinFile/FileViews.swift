// 文件列表（详细信息表格）、大图标网格、原生图标渲染
import AppKit
import SwiftUI

// MARK: - 原生图标

struct FileIconView: View {
    @ObservedObject private var localization = Localization.shared
    let item: FileItem
    var size: CGFloat = 18
    /// 观察关联设置：改动后徽标需立即更新（此前依赖 .task(id:)，
    /// 而 id 不含设置内容，导致改了打开方式要切换目录才生效）
    @ObservedObject private var defaultApps = DefaultAppService.shared
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.isContainer ? "folder.fill" : item.category.symbol)
                    .font(.system(size: size * 0.82))
                    .foregroundStyle(item.isContainer ? Color(nsColor: item.category.tint) : Color.secondary)
            }
        }
        .frame(width: size, height: size)
        // 右下角的关联应用徽标（表示双击时用哪个应用打开）
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(nsImage: badge)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: badgeSize, height: badgeSize)
                    // 白色描边让徽标在任何底图上都清晰
                    .background(
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .frame(width: badgeSize + 1.5, height: badgeSize + 1.5)
                    )
                    .offset(x: badgeSize * 0.18, y: badgeSize * 0.18)
            }
        }
        .task(id: "\(item.id)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size ?? 0)|\(size)") {
            await loadImage()
        }
    }

    /// 右下角徽标：直接同步计算。
    /// DefaultAppService 内部按扩展名缓存解析结果、按应用缓存图标，
    /// 因此重复求值不会频繁访问系统。
    private var badge: NSImage? {
        guard !item.isContainer, size >= 24, !AndroidURL.isAndroid(item.url) else { return nil }
        guard defaultApps.showsBadges else { return nil }
        return defaultApps.badgeIcon(for: item.url, size: badgeSize * 2)
    }

    /// 徽标尺寸：随图标大小缩放，但设上下限以免过大或看不清
    private var badgeSize: CGFloat {
        max(7, min(18, size * 0.42))
    }

    /// 加载图标或缩略图
    private func loadImage() async {
        // 安卓条目是设备上的路径，本机读不到，用符号图标兜底
        if AndroidURL.isAndroid(item.url) {
            image = nil
            return
        }

        // 图片、视频、PDF 在尺寸足够大时显示真实缩略图
        // （视频为封面帧，PDF 为首页渲染图）。
        // 小尺寸（列表行内 18pt）不生成，用系统图标即可，避免无谓开销。
        let wantsThumbnail = item.supportsThumbnail && size >= 32
        if wantsThumbnail {
            if let thumb = await ThumbnailService.shared.thumbnail(for: item.url, size: size, version: "\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size ?? 0)").image {
                guard !Task.isCancelled else { return }
                image = thumb
                return
            }
            // 生成失败（损坏或未支持的格式）→ 落到系统图标
        }

        guard !Task.isCancelled else { return }
        // NSWorkspace 提供系统真实图标（包含 Assets.car 中的系统应用图标）
        let loaded = await FileIconService.shared.thumbnail(for: item.url, size: size,
            version: "\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size ?? 0)")
        guard !Task.isCancelled else { return }
        image = loaded.image
    }
}

// MARK: - 详细信息表格

struct FileTableView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?

    private var selection: Binding<Set<String>> {
        Binding(
            get: { model.selectedIDs },
            set: { model.selectedIDs = $0 }
        )
    }

    var body: some View {
        table
            // 从分类/搜索跳转过来时，定位并选中目标文件
            .onReceive(model.$pendingSelectionID.compactMap { $0 }.receive(on: RunLoop.main)) { _ in
                selectPendingItem()
            }
            .onReceive(model.$items.combineLatest(model.$categoryResults, model.$searchResults).receive(on: RunLoop.main)) { _ in
                selectPendingItem()
            }
            // 行以下空白处的右键菜单（Windows 资源管理器行为）
            .background(
                EmptyAreaContextMenu(
                    buildMenu: { FileTableView.makeBackgroundMenu(model: model, dialog: $dialog) }
                )
                .frame(width: 0, height: 0)
            )
    }

    private func selectPendingItem() {
        guard let id = model.pendingSelectionID,
              model.displayedItems.contains(where: { $0.id == id }) else { return }
        model.selectedIDs = [id]
        _ = model.consumePendingSelection()
    }

    /// 表格本体（拆出来便于叠加背景捕获层）
    /// 表头排序绑定：点击列标题即按该列排序（与右键「排序方式」共用模型状态）
    private var sortOrder: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: { [SortOrderBridge.comparator(for: model.sortField, ascending: model.sortAscendingFlag)] },
            set: { newValue in
                guard let first = newValue.first,
                      let field = SortOrderBridge.field(for: first) else { return }
                model.sortField = field
                model.sortAscendingFlag = first.order == .forward
            }
        )
    }

    private var table: some View {
        Table(of: FileItem.self, selection: selection, sortOrder: sortOrder) {
            TableColumn(WLocalizedString("column.name", comment: "名称"), value: \FileItem.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    FileIconView(item: item, size: 18)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isSymlink {
                        Image(systemName: "arrowshape.turn.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .help(item.url.path)
            }
            .width(min: 200, ideal: 320)

            TableColumn(WLocalizedString("column.modified", comment: "修改日期"), value: \FileItem.sortableModified) { item in
                Text(item.modified.map(Self.dateText) ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 150)

            TableColumn(WLocalizedString("column.type", comment: "类型"), value: \FileItem.typeDescription, comparator: .localizedStandard) { item in
                Text(item.typeDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 140)

            TableColumn(WLocalizedString("column.size", comment: "大小"), value: \FileItem.sortableSize) { item in
                Text(item.sizeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        } rows: {
            ForEach(model.displayedItems) { item in
                TableRow(item).itemProvider { SidebarFolderDrop.provider(for: item.url) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let item = model.displayedItems.first(where: { $0.id == id }) {
                model.activate(item)
            }
        }
        .onDeleteCommand { model.deleteSelection() }
        // 双击打开：在底层 NSTableView 上直接挂 doubleAction。
        // 这比依赖 SwiftUI 的 primaryAction 可靠 —— 后者在部分情况下不会触发。
        .background(
            TableDoubleClickInstaller { table in
                TableColumnPreferences.install(on: table, kind: "files")
                TableDiagnostics.installDoubleClick(on: table) { row in
                    guard row >= 0, row < model.displayedItems.count else { return }
                    let item = model.displayedItems[row]
                    model.selectedIDs = [item.id]
                    // 安卓条目需要用 MTP 打开（本地 FileManager 不适用）
                    if AndroidURL.isAndroid(item.url) {
                        if let entry = model.androidEntries.first(where: { $0.path == item.url.path }) {
                            model.activateAndroid(entry)
                        }
                    } else {
                        model.activate(item)
                    }
                }
            }
            .frame(width: 0, height: 0)
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        // 使用 Table 提供的菜单目标，避免添加到侧边栏时误用此前选中的行。
        let _ = TabDiagnostics.shared.record(
            "itemMenu",
            detail: "系统给出选中=\(ids.count) 项 → \(ids.isEmpty ? "空白菜单" : "文件菜单")")
        if ids.isEmpty {
            emptyAreaMenu
        } else {
            FileItemContextMenu(engine: engine, model: model, dialog: $dialog,
                                item: model.displayedItems.first { ids.contains($0.id) }, contextIDs: ids)
        }
    }

    @ViewBuilder
    private var emptyAreaMenu: some View {
        FileBackgroundContextMenu(engine: engine, model: model, dialog: $dialog)
    }

    // MARK: - 空白处右键菜单（原生 NSMenu）

    static func makeBackgroundMenu(model: BrowserModel, dialog: Binding<DialogKind?>) -> NSMenu {
        let menu = NSMenu()
        let inFolder = model.currentDirectory != nil && !model.isCategoryView

        func add(_ title: String, _ action: @escaping () -> Void, enabled: Bool = true,
                 key: String = "", symbol: String? = nil) {
            let item = ClosureMenuItem(title: title, closure: action)
            item.isEnabled = enabled
            if !key.isEmpty { item.keyEquivalent = key }
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }

        if let directory = model.currentSidebarFolder {
            let alreadyAdded = model.engine.containsFolder(directory)
            add(alreadyAdded ? L("sidebar.add.already", "已在侧边栏")
                            : L("sidebar.add.current", "将当前文件夹添加到侧边栏"), {
                model.addFoldersToSidebar([directory])
            }, enabled: !alreadyAdded, symbol: "sidebar.left")
            menu.addItem(.separator())
        }

        // 新建
        add(L("action.newFolder", "新建文件夹"), { dialog.wrappedValue = .newFolder },
            enabled: inFolder, key: "N", symbol: "folder.badge.plus")
        add(L("action.newFile", "新建文本文档"), { dialog.wrappedValue = .newFile },
            enabled: inFolder, symbol: "doc.badge.plus")
        if model.clipboardHasText {
            add(L("action.pasteClipboardAsFile", "把剪贴板文本存成文件"), {
                _ = model.saveClipboardTextAsFile()
            }, enabled: inFolder, symbol: "doc.on.clipboard")
        }
        menu.addItem(.separator())

        // 粘贴
        add(L("action.paste", "粘贴"), { model.paste() },
            enabled: model.canPaste, key: "v", symbol: "clipboard")
        menu.addItem(.separator())

        // 排序
        let sortItem = NSMenuItem(title: L("menu.sortBy", "排序方式"), action: nil, keyEquivalent: "")
        sortItem.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        let sortMenu = NSMenu()
        for field in SortField.allCases {
            let item = ClosureMenuItem(title: field.localizedTitle, closure: { [weak model] in
                model?.sortField = field
            })
            item.state = model.sortField == field ? .on : .off
            sortMenu.addItem(item)
        }
        sortMenu.addItem(.separator())
        let ascending = ClosureMenuItem(title: L("menu.ascending", "升序"), closure: { [weak model] in
            model?.sortAscendingFlag = true
        })
        ascending.state = model.sortAscendingFlag ? .on : .off
        sortMenu.addItem(ascending)
        let descending = ClosureMenuItem(title: L("menu.descending", "降序"), closure: { [weak model] in
            model?.sortAscendingFlag = false
        })
        descending.state = model.sortAscendingFlag ? .off : .on
        sortMenu.addItem(descending)
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        // 视图
        let viewItem = NSMenuItem(title: L("menu.layout", "视图方式"), action: nil, keyEquivalent: "")
        viewItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        let viewMenu = NSMenu()
        let details = ClosureMenuItem(title: L("layout.details", "详细信息"), closure: { [weak model] in
            model?.setLayout(.details)
        })
        details.state = model.layout == .details ? .on : .off
        viewMenu.addItem(details)
        let icons = ClosureMenuItem(title: L("layout.icons", "大图标"), closure: { [weak model] in
            model?.setLayout(.icons)
        })
        icons.state = model.layout == .icons ? .on : .off
        viewMenu.addItem(icons)
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        let hidden = ClosureMenuItem(title: L("action.toggleHidden", "显示/隐藏隐藏文件"), closure: { [weak model] in
            model?.toggleHiddenFiles()
        })
        hidden.state = model.showHidden ? .on : .off
        hidden.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        menu.addItem(hidden)
        menu.addItem(.separator())

        // 刷新
        add(L("action.reload", "重新载入"), { model.reload() }, key: "r", symbol: "arrow.clockwise")

        // 在访达 / 终端中打开当前目录
        if let dir = model.currentDirectory {
            menu.addItem(.separator())
            add(L("action.revealHere", "在访达中显示当前文件夹"), {
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }, symbol: "magnifyingglass")
            add(L("action.copyCurrentPath", "复制当前文件夹路径"), {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(dir.path, forType: .string)
            }, symbol: "link")
        }

        return menu
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let directory = model.currentDirectory else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            model.copyFiles(urls, to: directory)
        }
        return true
    }

    static func dateText(_ date: Date) -> String {
        FileItem.formatDate(date)   // 统一实现在模型层，避免多处重复
    }
}

// MARK: - 大图标网格

struct FileIconGridView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?

    private struct LocateTarget: Equatable { let index: Int; let request = UUID() }
    @State private var locateTarget: LocateTarget?

    var body: some View {
        NativeIconGrid(items: model.displayedItems, selectedIDs: model.selectedIDs,
            locateIndex: locateTarget?.index, locateRequest: locateTarget?.request,
            makeTile: { AnyView(tile(for: $0)) })
            .onAppear { selectPendingItem() }
            .onReceive(model.$pendingSelectionID.compactMap { $0 }.receive(on: RunLoop.main)) { _ in
                selectPendingItem()
            }
            .onReceive(model.$items.combineLatest(model.$categoryResults, model.$searchResults).receive(on: RunLoop.main)) { _ in
                selectPendingItem()
            }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let directory = model.currentDirectory else { return false }
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                model.copyFiles(urls, to: directory)
            }
            return true
        }
        // 空白处右键菜单（与详细信息视图一致）
        // 未命中原生滚动容器的空白区域仍使用同一份菜单兜底。
        // 磁贴自己的菜单优先，仍由 FileItemContextMenu 处理。
        .contextMenu {
            FileBackgroundContextMenu(engine: engine, model: model, dialog: $dialog)
        }
        .background(
            EmptyAreaContextMenu(
                buildMenu: { FileTableView.makeBackgroundMenu(model: model, dialog: $dialog) }
            )
            .frame(width: 0, height: 0)
        )
    }

    private func selectPendingItem() {
        guard let id = model.pendingSelectionID,
              let index = model.displayedItems.firstIndex(where: { $0.id == id }) else { return }
        model.selectedIDs = [id]
        locateTarget = LocateTarget(index: index)
        _ = model.consumePendingSelection()
    }

    private func tile(for item: FileItem) -> some View {
        FileTile(item: item, selected: model.selectedIDs.contains(item.id))
            .modifier(LocalFileDrag(url: item.url))
            // 图标视图没有 NSTableView，双击通过标记交给窗口级鼠标监听处理
            .background(
                FileTileMarker(item: item) {
                    model.selectedIDs = [item.id]
                    model.activate(item)
                }
            )
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                model.select(item, extend: flags.contains(.shift), toggle: flags.contains(.command))
            }
            .onTapGesture(count: 2) { model.activate(item) }
            // 与列表视图共用同一份菜单，保证功能完全一致
            .contextMenu {
                FileItemContextMenu(engine: engine, model: model, dialog: $dialog, item: item)
            }
    }
}

/// Table 的空目标菜单与网格空白区域共用，覆盖未命中 NSScrollView 的区域。
struct FileBackgroundContextMenu: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?

    var body: some View {
        if let directory = model.currentSidebarFolder {
            Button(engine.containsFolder(directory)
                   ? L("sidebar.add.already", "已在侧边栏")
                   : L("sidebar.add.current", "将当前文件夹添加到侧边栏")) {
                model.addFoldersToSidebar([directory])
            }
            .disabled(engine.containsFolder(directory))
            Divider()
        }
        Button(WLocalizedString("action.newFolder", comment: "新建文件夹")) { dialog = .newFolder }
            .disabled(!model.supportsDirectoryCreation)
        Button(WLocalizedString("action.newFile", comment: "新建文本文档")) { dialog = .newFile }
            .disabled(!model.supportsDirectoryCreation)
        if model.clipboardHasText {
            Button(WLocalizedString("action.pasteClipboardAsFile", comment: "把剪贴板文本存成文件")) {
                _ = model.saveClipboardTextAsFile()
            }
            .disabled(!model.supportsDirectoryCreation)
        }
        Divider()
        Button(WLocalizedString("action.paste", comment: "粘贴")) { model.paste() }
            .disabled(!model.canPaste)
        Divider()
        Button(WLocalizedString("action.toggleHidden", comment: "显示/隐藏隐藏文件")) { model.toggleHiddenFiles() }
        Button(WLocalizedString("action.reload", comment: "重新载入")) { model.reload() }
    }
}


/// 文件右键菜单（列表视图与图标视图**共用同一份**，保证功能一致）
struct FileItemContextMenu: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?
    /// 被右键的那一项（单选时用于「打开方式」「重命名」）
    let item: FileItem?
    var contextIDs: Set<String>? = nil
    /// 当前选中项（多选时部分操作作用于全部选中项）
    var selectedCount: Int { model.selectedCount }

    private var sidebarTargets: [FileItem] {
        model.sidebarContextItems(item: item, ids: contextIDs)
    }

    private var sidebarFolders: [FileItem] {
        sidebarTargets.filter { $0.isBrowsableFolder && $0.url.isFileURL && $0.url.pathExtension.lowercased() != "app" }
    }

    private var archiveTargets: [URL] {
        sidebarTargets.filter { !$0.isDirectory && $0.url.isFileURL && ArchiveService.isArchive($0.url) }.map(\.url)
    }

    private var singleContextArchive: URL? { sidebarTargets.count == 1 ? archiveTargets.first : nil }

    var body: some View {
        Button(WLocalizedString("action.open", comment: "打开")) { model.openSelection() }
        if !sidebarFolders.isEmpty {
            let alreadyAdded = sidebarFolders.allSatisfy { engine.containsFolder($0.url) }
            Button(alreadyAdded ? L("sidebar.add.already", "已在侧边栏")
                   : sidebarFolders.count == 1 ? L("sidebar.add.folder", "添加到侧边栏")
                   : L("sidebar.add.folders", "将 %d 个文件夹添加到侧边栏", sidebarFolders.count)) {
                model.addFoldersToSidebar(sidebarTargets.map(\.url))
            }
            .disabled(alreadyAdded)
        }
        if !model.isAndroidPath || !model.selectedAndroidEntries.filter({ !$0.isDirectory }).isEmpty {
            Button(L("action.quickLook", "快速预览")) {
                if let archive = singleContextArchive { model.previewArchive(archive) }
                else { model.previewSelection() }
            }
        }
        // 安卓文件在本机没有可用的打开方式，只在本地条目上提供
        if selectedCount <= 1, let item, !AndroidURL.isAndroid(item.url) {
            Button(WLocalizedString("action.openWith", comment: "打开方式…")) { dialog = .openWith(item) }
            // 仅在本应用内生效的默认打开方式（不改动 macOS 的关联设置）
            Menu(L("assoc.menu", "默认打开方式（仅本应用）")) {
                if let ext = FileAssociations.key(for: item.url) {
                    let current = FileAssociations.shared.displayName(forExtension: ext)
                    Text(current == nil
                         ? L("assoc.currentSystem", "当前：跟随系统")
                         : L("assoc.current", "当前：%@", current ?? ""))
                    Divider()
                    // 候选应用：系统为该类型推荐的 + 手动选择
                    ForEach(engine.applications(for: item), id: \.path) { app in
                        Button(app.deletingPathExtension().lastPathComponent) {
                            model.setDefaultApplication(app, for: item)
                        }
                    }
                    Divider()
                    Button(L("assoc.choose", "选择其它应用…")) { dialog = .openWith(item) }
                    if current != nil {
                        Button(L("assoc.clear", "恢复跟随系统")) {
                            model.clearDefaultApplication(for: item)
                        }
                    }
                } else {
                    Text(L("assoc.error.noExtension", "该文件没有扩展名，无法按类型设置。"))
                }
            }
        }
        // 分类视图与搜索结果中的文件不在当前目录，提供"回到真实位置"的入口
        if let item, model.isAggregatedView, !AndroidURL.isAndroid(item.url) {
            Button(L("action.openContainingFolder", "打开所在文件夹")) {
                model.openContainingFolder(of: item)
            }
        }
        Divider()
        if let item, AndroidURL.isAndroid(item.url) {
            Button(L("android.downloadToLocal", "下载到本机…")) {
                model.downloadSelectedToLocalFolder()
            }
        } else {
            Button(WLocalizedString("action.reveal", comment: "在访达中显示")) { model.revealSelection() }
        }
        Divider()
        Button(WLocalizedString("action.cut", comment: "剪切")) { model.cutSelectionToClipboard() }
        Button(WLocalizedString("action.copy", comment: "复制")) { model.copySelectionToClipboard() }
        if selectedCount == 1, let item, item.isDirectory {
            Button(WLocalizedString("action.pasteInto", comment: "粘贴到此处")) { model.paste() }
                .disabled(!model.canPaste)
        }
        Menu(WLocalizedString("action.copyAs", comment: "复制为")) {
            Button(WLocalizedString("action.copyPath", comment: "完整路径")) { model.copyPathToClipboard() }
            Button(WLocalizedString("action.copyName", comment: "文件名")) { model.copyNameToClipboard() }
            Button(WLocalizedString("action.copyDir", comment: "所在目录")) {
                model.copyPathToClipboard(includeDirectory: true)
            }
        }
        Divider()
        // 压缩与解压（安卓路径不适用，走 MTP 无对应能力）
        if !model.isAndroidPath {
            if let archive = singleContextArchive {
                Button(L("archive.preview.title", "预览压缩包")) { model.previewArchive(archive) }
            }
            if model.canMutateFiles, !archiveTargets.isEmpty {
                Button(model.currentDirectory == nil ? L("action.extractBeside", "解压到所在文件夹") : L("action.extractHere", "解压到当前文件夹")) { model.extractArchives(archiveTargets) }
                Button(L("action.extractFolder", "解压到独立文件夹")) { model.extractArchives(archiveTargets, createFolder: true) }
                Button(L("action.extractTo", "解压到…")) { model.chooseExtractionDestination(for: archiveTargets) }
            }
            Button(L("action.compress", "压缩为 zip")) { model.compressSelection() }
                .disabled(!model.canCompress)
            Divider()
        }
        Button(WLocalizedString("menu.duplicate", comment: "制作副本")) { model.duplicateSelection() }
        if selectedCount > 1, !model.isAndroidPath {
            Button(L("rename.batch", "批量重命名")) { dialog = .batchRename(model.selectedItems) }
                .disabled(!model.canMutateFiles)
        }
        Button(WLocalizedString("action.rename", comment: "重命名…")) {
            if let target = item ?? model.selectedItems.first { dialog = .rename(target) }
        }
        .disabled(selectedCount != 1)
        Button(model.deleteActionTitle, role: .destructive) {
            model.deleteSelection()
        }
        Divider()
        Button(WLocalizedString("action.getInfo", comment: "显示简介")) {
            NotificationCenter.default.post(name: .winFileGetInfo, object: nil)
        }
    }
}

struct FileTile: View {
    @ObservedObject private var localization = Localization.shared
    let item: FileItem
    let selected: Bool
    @ObservedObject private var defaultApps = DefaultAppService.shared

    var body: some View {
        NativeFileTile(item: item, selected: selected, badge: badge)
        .frame(maxWidth: .infinity, minHeight: IconGridMetrics.pitch - 10, maxHeight: IconGridMetrics.pitch - 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.name + " " + (item.isContainer ? item.typeDescription : item.sizeText)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var badge: NSImage? {
        guard !item.isContainer, defaultApps.showsBadges, !AndroidURL.isAndroid(item.url) else { return nil }
        return defaultApps.badgeIcon(for: item.url, size: 36)
    }
}
