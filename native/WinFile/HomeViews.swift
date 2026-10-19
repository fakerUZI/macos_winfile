// 主页（Home）与此电脑（This PC）——对应 Windows 资源管理器的两个页面
import AppKit
import SwiftUI

// MARK: - 主页

struct HomeView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    /// 唯一真相来源：每次求值都从 TabManager 解析当前模型，绝不缓存副本
    @ObservedObject var manager: TabManager

    /// 当前页签的浏览模型
    private var model: BrowserModel { manager.activeModel }

    private let tileColumns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 12)]

    /// 主页/此电脑需要各自的背景菜单（与文件夹视图一致的入口）
    @State private var pageMarker: NSView?

    private func pageBackgroundMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void, symbol: String? = nil, enabled: Bool = true) {
            let item = ClosureMenuItem(title: title, closure: action)
            item.isEnabled = enabled
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if model.isHomeView {
            add(L("home.quickAccess", "快速访问"), { model.loadHome() }, symbol: "arrow.clockwise")
            if !model.recentEntries.isEmpty {
                add(L("home.clearHistory", "清除打开记录"), { model.clearRecentHistory() }, symbol: "clock.arrow.circlepath")
            }
            menu.addItem(.separator())
        }
        add(L("view.thisPC", "此电脑"), { model.loadThisPC() }, symbol: "internaldrive")
        add(L("view.applications", "应用程序"), { model.navigate(to: .applications) }, symbol: "square.grid.2x2")
        menu.addItem(.separator())
        add(L("action.newFolder", "新建文件夹"), { model.createFolder(named: L("default.newFolderName", "新建文件夹")) },
            symbol: "folder.badge.plus", enabled: model.currentDirectory != nil)
        add(L("action.paste", "粘贴"), { model.paste() },
            symbol: "clipboard", enabled: model.currentDirectory != nil && model.clipboard != nil)
        return menu
    }

    /// 页面背景（用于空白处右键）
    private var pageBackground: some View {
        EmptyAreaContextMenu(
            buildMenu: { pageBackgroundMenu() },
            onMarker: { pageMarker = $0 }
        )
        .frame(width: 0, height: 0)
        .background(Color.clear)
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                quickAccessSection
                if !model.pinnedFolders.isEmpty {
                    favoritesSection
                }
                recentSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(pageBackground)
    }

    // MARK: 快速访问

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("home.quickAccess", "快速访问"),
                          subtitle: L("home.quickAccess.subtitle", "常用文件夹"))
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ForEach(model.quickAccess) { place in
                    FolderTile(engine: engine, place: place,
                               pinned: model.isPinned(place.url),
                               // 注意：闭包内必须重新解析当前模型。
                               // 直接捕获 `model` 会拿到结构体副本里的过期实例，
                               // 表现为"点了快速访问不跳转"。
                               open: {
                                   TabDiagnostics.shared.record("home.openQuickAccess",
                                                                detail: "位置=\(place.name)")
                                   manager.activeModel.selectFolder(place.url)
                               },
                               togglePin: { manager.activeModel.togglePin(place.url) })
                }
            }
        }
    }

    // MARK: 收藏夹

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("home.favorites", "收藏夹"),
                          subtitle: L("home.favorites.subtitle", "已固定的文件夹（%d）", model.pinnedFolders.count))
            VStack(spacing: 0) {
                ForEach(Array(model.pinnedFolders.enumerated()), id: \.element.path) { index, url in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color(nsColor: .systemYellow))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).fontWeight(.medium)
                            Text(FileSystemService.abbreviate(url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button {
                            model.togglePin(url)
                        } label: {
                            Image(systemName: "pin.slash")
                        }
                        .buttonStyle(.borderless)
                        .help(L("home.unpin", "取消固定"))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        TabDiagnostics.shared.record("home.openPinned", detail: "位置=\(url.lastPathComponent)")
                        manager.activeModel.selectFolder(url)
                    }
                    if index < model.pinnedFolders.count - 1 {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
    }

    // MARK: 最近使用

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(L("home.recent", "最近使用"),
                              subtitle: L("home.recent.subtitle", "最近修改与打开过的文件"))
                Spacer()
                if !model.recentEntries.isEmpty {
                    Button(L("home.clearHistory", "清除打开记录")) { model.clearRecentHistory() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if model.isLoadingHome {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("home.loading", "正在整理…")).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else if model.recentEntries.isEmpty {
                Text(L("home.recent.empty", "最近没有修改或打开过文件。"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                let shown = model.showAllRecent ? model.recentEntries : Array(model.recentEntries.prefix(12))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        RecentRow(engine: engine, entry: entry, model: model)
                        if index < shown.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

                if model.recentEntries.count > 12 {
                    Button(model.showAllRecent
                           ? L("home.showLess", "收起")
                           : L("home.showMore", "展开全部 %d 项", model.recentEntries.count)) {
                        model.showAllRecent.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3).fontWeight(.semibold)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 快速访问磁贴

struct FolderTile: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    let place: SidebarPlace
    let pinned: Bool
    let open: () -> Void
    let togglePin: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            // 图标与文字作为一个整体放在同一个方框内。
            // 此前用 Spacer 撑开，导致图标浮在方框上方、与文字脱节。
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: place.symbol)
                        .font(.system(size: 24))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                        .frame(width: 30, height: 30, alignment: .center)
                    Text(place.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(FileSystemService.abbreviate(place.url))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: hovering ? .selectedContentBackgroundColor.withAlphaComponent(0.12) : .controlBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("action.open", "打开"), action: open)
            Button(pinned ? L("home.unpin", "从主页取消固定") : L("home.pin", "固定到主页收藏夹"), action: togglePin)
            Divider()
            Button(L("action.reveal", "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([place.url])
            }
            Button(L("action.copyPath", "复制完整路径")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(place.url.path, forType: .string)
            }
        }
    }
}

// MARK: - 最近使用行

struct RecentRow: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    let entry: RecentEntry
    @ObservedObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(engine: engine, item: entry.item, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(FileSystemService.abbreviate(entry.item.url.deletingLastPathComponent()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(entry.timeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.item.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if entry.openedRecently {
                Text(L("recent.openedBadge", "已打开"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(hovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.openRecent(entry) }
        .contextMenu {
            Button(L("action.open", "打开")) { model.openRecent(entry) }
            Button(L("action.reveal", "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([entry.item.url])
            }
            Button(L("home.openContaining", "打开所在文件夹")) {
                model.openContainingFolder(of: entry.item)
            }
            Divider()
            Button(L("action.copyPath", "复制完整路径")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.item.url.path, forType: .string)
            }
        }
    }
}

// MARK: - 此电脑

struct ThisPCView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    /// 与 HomeView 同理：每次求值都从 TabManager 解析当前模型
    @ObservedObject var manager: TabManager

    private var model: BrowserModel { manager.activeModel }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 14)]
    @State private var pageMarker: NSView?

    private func pageBackgroundMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void, symbol: String? = nil, enabled: Bool = true) {
            let item = ClosureMenuItem(title: title, closure: action)
            item.isEnabled = enabled
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        add(L("thispc.refresh", "刷新磁盘信息"), { model.loadThisPC() }, symbol: "arrow.clockwise")
        add(L("view.home", "主页"), { model.loadHome() }, symbol: "house")
        menu.addItem(.separator())
        add(L("thispc.showAll", "显示全部驱动器"), { model.loadThisPC() }, symbol: "internaldrive")
        return menu
    }

    private var pageBackground: some View {
        EmptyAreaContextMenu(
            buildMenu: { pageBackgroundMenu() },
            onMarker: { pageMarker = $0 }
        )
        .frame(width: 0, height: 0)
        .background(Color.clear)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("thispc.drives", "设备和驱动器")).font(.title3).fontWeight(.semibold)
                        Text(L("thispc.drives.subtitle", "%d 个驱动器", model.drives.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.isLoadingDrives {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("thispc.loading", "正在读取…")).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(model.drives) { drive in
                                DriveCard(engine: engine, drive: drive, model: model)
                            }
                        }
                    }
                }

                if !engine.authorizedRoots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("thispc.authorized", "已授权文件夹")).font(.title3).fontWeight(.semibold)
                        VStack(spacing: 0) {
                            ForEach(Array(engine.authorizedRoots.enumerated()), id: \.element.path) { index, url in
                                HStack(spacing: 10) {
                                    Image(systemName: "lock.open.fill")
                                        .foregroundStyle(Color(nsColor: .systemGreen))
                                    Text(url.lastPathComponent).fontWeight(.medium)
                                    Text(FileSystemService.abbreviate(url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectFolder(url) }
                                if index < engine.authorizedRoots.count - 1 {
                                    Divider().padding(.leading, 34)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .background(pageBackground)
    }
}

// MARK: - 驱动器卡片

struct DriveCard: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    let drive: DriveInfo
    @ObservedObject var model: BrowserModel
    @State private var hovering = false
    @State private var showInfo = false

    var body: some View {
        Button {
            model.selectFolder(drive.url)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: drive.symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(drive.name).fontWeight(.semibold).lineLimit(1)
                        Text(drive.kindDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if drive.isEjectable {
                        Image(systemName: "eject")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 容量进度条（对应 Windows 的驱动器容量条）
                if drive.showsCapacityBar {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: drive.barColor))
                                .frame(width: max(2, geometry.size.width * drive.usedFraction))
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 4) {
                        Text(L("drive.free", "%@ 可用", drive.freeText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(L("drive.total", "共 %@", drive.totalText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("drive.imageHint", "只读映像 · 大小 %@", drive.totalText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: hovering ? .selectedContentBackgroundColor.withAlphaComponent(0.12) : .controlBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("action.open", "打开")) { model.selectFolder(drive.url) }
            Button(L("drive.info", "获取信息")) { showInfo = true }
            if drive.isEjectable && !drive.isRoot {
                Divider()
                Button(L("drive.eject", "弹出")) { _ = model.eject(drive) }
            }
            Divider()
            Button(L("action.copyPath", "复制完整路径")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(drive.url.path, forType: .string)
            }
            Button(L("drive.openInFinder", "在访达中打开")) {
                NSWorkspace.shared.activateFileViewerSelecting([drive.url])
            }
        }
        .alert(L("drive.info", "获取信息"), isPresented: $showInfo) {
            Button(L("button.ok", "好"), role: .cancel) { }
        } message: {
            Text("""
            \(drive.name)
            \(L("drive.kind", "类型"))：\(drive.kindDescription)
            \(L("drive.fileSystem", "文件系统"))：\(drive.fileSystem ?? "—")
            \(L("drive.capacity", "容量"))：\(drive.totalText)
            \(L("drive.used", "已用"))：\(drive.usedText)（\(Int(drive.usedFraction * 100))%）
            \(L("drive.available", "可用"))：\(drive.freeText)
            """)
        }
    }
}
