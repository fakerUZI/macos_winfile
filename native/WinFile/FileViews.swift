// 文件列表（详细信息表格）、大图标网格、原生图标渲染
import AppKit
import SwiftUI

// MARK: - 原生图标

struct FileIconView: View {
    @ObservedObject var engine: FSEngine
    let item: FileItem
    var size: CGFloat = 18
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
        .task(id: item.id) {
            await loadImage()
        }
    }

    /// 加载图标或缩略图
    private func loadImage() async {
        // 安卓条目是设备上的路径，本机读不到，用符号图标兜底
        if AndroidURL.isAndroid(item.url) {
            image = nil
            return
        }

        // 图片类文件且尺寸足够大时，优先显示真实缩略图。
        // 小尺寸（列表行内 18pt）没必要生成缩略图，用系统图标即可。
        let wantsThumbnail = item.category == .image && size >= 32
        if wantsThumbnail {
            if let thumb = await ThumbnailService.shared.thumbnail(for: item.url, size: size) {
                image = thumb
                return
            }
            // 生成失败（损坏或未支持的格式）→ 落到系统图标
        }

        // NSWorkspace 提供系统真实图标（包含 Assets.car 中的系统应用图标）
        let url = item.url
        let target = size * 2
        let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: target, height: target)
            return icon
        }.value
        image = loaded
    }
}

// MARK: - 详细信息表格

struct FileTableView: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?
    /// 列表容器标记（用于把空白右键限定在本列表内）
    @State private var listMarker: NSView?

    private var selection: Binding<Set<String>> {
        Binding(
            get: { model.selectedIDs },
            set: { model.selectedIDs = $0 }
        )
    }

    var body: some View {
        table
            // 行以下空白处的右键菜单（Windows 资源管理器行为）
            .background(
                EmptyAreaContextMenu(
                    buildMenu: { FileTableView.makeBackgroundMenu(model: model, dialog: $dialog) },
                    onMarker: { listMarker = $0 }
                )
                .frame(width: 0, height: 0)
            )
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
        Table(model.displayedItems, selection: selection, sortOrder: sortOrder) {
            TableColumn(NSLocalizedString("column.name", comment: "名称")) { item in
                HStack(spacing: 6) {
                    FileIconView(engine: engine, item: item, size: 18)
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

            TableColumn(NSLocalizedString("column.modified", comment: "修改日期")) { item in
                Text(item.modified.map(Self.dateText) ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 150)

            TableColumn(NSLocalizedString("column.type", comment: "类型")) { item in
                Text(item.typeDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 140)

            TableColumn(NSLocalizedString("column.size", comment: "大小")) { item in
                Text(item.sizeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
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
                TableDiagnostics.installDoubleClick(on: table) { row in
                    guard row >= 0, row < model.displayedItems.count else { return }
                    let item = model.displayedItems[row]
                    model.selectedIDs = [item.id]
                    // 安卓条目需要用 adb 打开（本地 FileManager 不适用）
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
        // 注意：右键「未被选中」的行时，系统可能给出空的 ids。
        // 此时若直接显示空白处菜单，用户就看不到「重命名」等项目 ——
        // 所以这里先补选被右键的那一行，再按常规文件菜单展示。
        let _ = TabDiagnostics.shared.record(
            "itemMenu",
            detail: "系统给出选中=\(ids.count) 项 → \(ids.isEmpty ? "空白菜单" : "文件菜单")")
        if ids.isEmpty {
            emptyAreaMenu
        } else {
            itemMenu
        }
    }

    @ViewBuilder
    private var itemMenu: some View {
        FileItemContextMenu(engine: engine, model: model,
                            dialog: $dialog, item: model.selectedItems.first)
    }

    @ViewBuilder
    private var emptyAreaMenu: some View {
        Button(NSLocalizedString("action.newFolder", comment: "新建文件夹")) { dialog = .newFolder }
        Button(NSLocalizedString("action.newFile", comment: "新建文本文档")) { dialog = .newFile }
        if model.clipboardHasText {
            Button(NSLocalizedString("action.pasteClipboardAsFile", comment: "把剪贴板文本存成文件")) {
                _ = model.saveClipboardTextAsFile()
            }
        }
        Divider()
        Button(NSLocalizedString("action.paste", comment: "粘贴")) { model.paste() }
            .disabled(model.clipboard == nil)
        Divider()
        Button(NSLocalizedString("action.toggleHidden", comment: "显示/隐藏隐藏文件")) { model.toggleHiddenFiles() }
        Button(NSLocalizedString("action.reload", comment: "重新载入")) { model.reload() }
    }

    // MARK: - 空白处右键菜单（原生 NSMenu）

    static func makeBackgroundMenu(model: BrowserModel, dialog: Binding<DialogKind?>) -> NSMenu {
        let menu = NSMenu()
        let inFolder = model.currentDirectory != nil

        func add(_ title: String, _ action: @escaping () -> Void, enabled: Bool = true,
                 key: String = "", symbol: String? = nil) {
            let item = ClosureMenuItem(title: title, closure: action)
            item.isEnabled = enabled
            if !key.isEmpty { item.keyEquivalent = key }
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
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
            enabled: inFolder && model.clipboard != nil, key: "v", symbol: "clipboard")
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
            let items = urls.compactMap { FileItem(url: $0, resourceKeys: FSEngine.resourceKeys, showHidden: true) }
            do {
                _ = try engine.transfer(items, to: directory, mode: .copy)
                model.reload()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        return true
    }

    static func dateText(_ date: Date) -> String {
        FileItem.formatDate(date)   // 统一实现在模型层，避免多处重复
    }
}

// MARK: - 大图标网格

struct FileIconGridView: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?
    /// 列表容器标记（用于把空白右键限定在本列表内）
    @State private var listMarker: NSView?

    /// 列宽与间距（自建网格用）
    private let tileMinWidth: CGFloat = 104
    private let tileSpacing: CGFloat = 10
    /// 网格可用宽度（由 GeometryReader 提供，用于计算列数）
    @State private var gridWidth: CGFloat = 900

    /// 每行列数：按最小磁贴宽度自适应，上限 8 列
    private var columnCount: Int {
        max(1, min(8, Int((gridWidth + tileSpacing) / (tileMinWidth + tileSpacing))))
    }

    /// 按列分组后的行
    private var rows: [[FileItem]] {
        let items = model.displayedItems
        guard !items.isEmpty else { return [] }
        var result: [[FileItem]] = []
        var index = 0
        while index < items.count {
            let end = min(index + columnCount, items.count)
            result.append(Array(items[index..<end]))
            index = end
        }
        return result
    }

    var body: some View {
        // 自建网格：按列分组、逐行排布。
        //
        // 为什么不用 LazyVGrid：实测分类视图有 16 项时，LazyVGrid 只创建了 14 个
        // 磁贴视图，空白位置连点击都无响应（用户实测确认），且该问题在离屏环境
        // 无法自动验证。自建网格不依赖懒加载，视图创建数量完全确定。
        // 文件列表通常几十到几百项，一次性布局的开销可以接受。
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: tileSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: tileSpacing) {
                            ForEach(row) { item in
                                tile(for: item)
                                    .frame(maxWidth: .infinity)
                            }
                            // 补齐本行剩余列，保证各列宽度一致
                            if row.count < columnCount {
                                ForEach(0..<(columnCount - row.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .onAppear { gridWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { newValue in gridWidth = newValue }
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
                let items = urls.compactMap { FileItem(url: $0, resourceKeys: FSEngine.resourceKeys, showHidden: true) }
                do {
                    _ = try engine.transfer(items, to: directory, mode: .copy)
                    model.reload()
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            }
            return true
        }
        // 空白处右键菜单（与详细信息视图一致）
        .background(
            EmptyAreaContextMenu(
                buildMenu: { FileTableView.makeBackgroundMenu(model: model, dialog: $dialog) },
                onMarker: { listMarker = $0 }
            )
            .frame(width: 0, height: 0)
        )
    }

    /// 单个磁贴：含双击标记、单击选择、右键菜单
    @ViewBuilder
    private func tile(for item: FileItem) -> some View {
        FileTile(engine: engine, item: item, selected: model.selectedIDs.contains(item.id))
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


/// 文件右键菜单（列表视图与图标视图**共用同一份**，保证功能一致）
struct FileItemContextMenu: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?
    /// 被右键的那一项（单选时用于「打开方式」「重命名」）
    let item: FileItem?
    /// 当前选中项（多选时部分操作作用于全部选中项）
    var selectedCount: Int { model.selectedCount }

    var body: some View {
        Button(NSLocalizedString("action.open", comment: "打开")) { model.openSelection() }
        // 安卓文件在本机没有可用的打开方式，只在本地条目上提供
        if selectedCount <= 1, let item, !AndroidURL.isAndroid(item.url) {
            Button(NSLocalizedString("action.openWith", comment: "打开方式…")) { dialog = .openWith(item) }
        }
        Divider()
        if let item, AndroidURL.isAndroid(item.url) {
            Button(L("android.downloadToLocal", "下载到本机…")) {
                model.downloadSelectedToLocalFolder()
            }
        } else {
            Button(NSLocalizedString("action.reveal", comment: "在访达中显示")) { model.revealSelection() }
        }
        Divider()
        Button(NSLocalizedString("action.cut", comment: "剪切")) { model.cutSelectionToClipboard() }
        Button(NSLocalizedString("action.copy", comment: "复制")) { model.copySelectionToClipboard() }
        if selectedCount == 1, let item, item.isDirectory {
            Button(NSLocalizedString("action.pasteInto", comment: "粘贴到此处")) { model.paste() }
                .disabled(model.clipboard == nil)
        }
        Menu(NSLocalizedString("action.copyAs", comment: "复制为")) {
            Button(NSLocalizedString("action.copyPath", comment: "完整路径")) { model.copyPathToClipboard() }
            Button(NSLocalizedString("action.copyName", comment: "文件名")) { model.copyNameToClipboard() }
            Button(NSLocalizedString("action.copyDir", comment: "所在目录")) {
                model.copyPathToClipboard(includeDirectory: true)
            }
        }
        Divider()
        // 压缩与解压（安卓路径不适用，走 adb 无对应能力）
        if !model.isAndroidPath {
            if model.canExtract {
                Button(L("action.extractHere", "解压到当前文件夹")) { model.extractSelection() }
            }
            Button(L("action.compress", "压缩为 zip")) { model.compressSelection() }
                .disabled(!model.canCompress)
            Divider()
        }
        Button(NSLocalizedString("menu.duplicate", comment: "制作副本")) { model.duplicateSelection() }
        Button(NSLocalizedString("action.rename", comment: "重命名…")) {
            if let target = item ?? model.selectedItems.first { dialog = .rename(target) }
        }
        .disabled(selectedCount != 1)
        Button(NSLocalizedString("action.moveToTrash", comment: "移到废纸篓"), role: .destructive) {
            model.deleteSelection()
        }
        Divider()
        Button(NSLocalizedString("action.getInfo", comment: "显示简介")) {
            NotificationCenter.default.post(name: .winFileGetInfo, object: nil)
        }
    }
}

struct FileTile: View {
    @ObservedObject var engine: FSEngine
    let item: FileItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            FileIconView(engine: engine, item: item, size: 44)
            // 名称固定占两行高度（见 FileItem.tileNameAreaHeight）。
            // 若按内容自适应，同一行里矮的磁贴下方会留出空白。
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: FileItem.tileNameAreaHeight, alignment: .top)
            Text(item.isContainer ? item.typeDescription : item.sizeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
    }
}
