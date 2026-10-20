import AppKit
import SwiftUI

struct StorageCleanupView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var store: StorageCleanupModel
    @ObservedObject var model: BrowserModel
    var nestedInHub = false
    @State private var showsDetails = false
    @State private var showsSettings = false
    @State private var showsFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summary
            filters
            files.frame(minHeight: 100)
            footer
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showsFolderPicker) {
            FolderPickerSheet(initialDirectory: (store.isBaidu ? store.downloadFolder : store.largeFolder) ?? FileSystemService.realHomeDirectory(),
                              title: store.folderPickerTitle) { url in
                store.chooseFolder(url) ? nil : store.message
            }
        }
        .onChange(of: store.message) { if $0 != nil && !showsFolderPicker { showsDetails = true } }
        .popover(isPresented: $showsDetails) { details }
        .popover(isPresented: $showsSettings) { settings }
        .alert(L("cleanup.confirm", "将所选文件移到废纸篓？"), isPresented: $store.confirmsTrash) {
            Button(L("action.moveToTrash", "移到废纸篓"), role: .destructive) { store.clean() }
            Button(L("button.cancel", "取消"), role: .cancel) {}
        } message: {
            Text(store.isBaidu ? L("software.baiduConfirm", "共 %d 项（%@）。下载文件是个人资料，请核对后再清理；请先退出百度网盘。执行前会复查文件身份与占用状态。", store.pendingFiles.count,
                   FileItem.formatSize(store.pendingFiles.reduce(0) { $0 + $1.size })) : store.softwareMode ? L("software.confirm", "共 %d 项（%@），仅限当前软件的缓存和日志。执行前会复查文件身份、应用运行及占用状态。", store.pendingFiles.count,
                   FileItem.formatSize(store.pendingFiles.reduce(0) { $0 + $1.size })) : L("cleanup.confirmDetail", "共 %d 项（%@）。附件、下载文件、安装包和大文件可能是你需要保留的资料，请先核对。执行前会复查文件身份、应用运行及占用状态。", store.pendingFiles.count,
                   FileItem.formatSize(store.pendingFiles.reduce(0) { $0 + $1.size })))
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(store.softwareMode ? store.softwareTitle : (nestedInHub ? L("cleanup.general", "通用清理") : L("cleanup.title", "空间清理")), systemImage: "externaldrive.badge.minus").font(.title3.bold())
                if store.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("cleanup.settings", "扫描设置")) { showsSettings = true }.disabled(store.busy)
                Button(L("cleanup.details", "扫描详情 / 忽略 / 历史")) { showsDetails = true }
                if store.busy { Button(L("button.cancel", "取消")) { store.cancel() } }
                else { Button(store.hasScanned ? L("appData.rescan", "重新扫描") : L("cleanup.scan", "开始扫描")) { store.scan() } }
            }
            Text(store.isBaidu ? L("software.baiduScope", "下载文件单独展示，不限大小和时间；跳过未完成任务。缓存和日志默认保留最近 7 天，运行时跳过。扫描不会删除文件，清理前请退出百度网盘。") : store.softwareMode ? L("software.cacheScope", "仅扫描当前软件的可重建缓存和日志；运行中的软件会跳过。扫描不会删除文件。") : L("cleanup.scope", "扫描应用缓存、日志、安装包、个人大文件、微信附件与网盘下载文件；扫描不会删除文件。"))
                .font(.caption).foregroundStyle(.secondary)
            if store.isBaidu {
                HStack {
                    Button(store.folderPickerTitle) { showsFolderPicker = true }.disabled(store.busy)
                    Button(L("software.baiduDefaultFolders", "恢复常见下载目录")) { store.useDefaultDownloadFolders() }.disabled(store.busy)
                }
                Text(store.downloadScopeDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if store.result.cancelled || store.result.limited || !store.result.inaccessible.isEmpty {
                Label(store.result.cancelled ? L("cleanup.cancelled", "已取消，结果不完整。") : L("cleanup.partial", "扫描有上限或部分目录无法读取，结果不完整。可在扫描设置中选择单一类别缩小范围。"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("cleanup.settings", "扫描设置")).font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker(L("cleanup.scanScope", "本次扫描"), selection: $store.scanScope) {
                        Text(L("wechat.all", "全部类型")).tag("all")
                        ForEach(store.availableKinds) { Text($0.title).tag($0.rawValue) }
                    }
                    if !store.softwareMode {
                    Picker(L("cleanup.threshold", "大文件至少"), selection: $store.minimumLargeMB) {
                        Text("100 MB").tag(100); Text("500 MB").tag(500); Text("1 GB").tag(1024)
                    }
                    }
                }
                Text(store.softwareMode ? L("software.age", "缓存 / 日志保留") : L("cleanup.age", "缓存 / 日志 / 安装包保留")).font(.caption)
                Picker(L("cleanup.age", "缓存 / 日志 / 安装包保留"), selection: $store.minimumAgeDays) {
                    Text(L("cleanup.age0", "不限时间")).tag(0)
                    Text(L("cleanup.age7", "最近 7 天不清理")).tag(7)
                    Text(L("cleanup.age30", "最近 30 天不清理")).tag(30)
                }.labelsHidden()
                if !store.softwareMode {
                HStack {
                    Button(L("cleanup.chooseFolder", "选择大文件扫描目录…")) { showsSettings = false; showsFolderPicker = true }
                    Button(L("cleanup.defaultFolders", "恢复默认大文件扫描范围")) { store.useDefaultFolders() }
                }
                Text(store.largeFolder?.path ?? L("cleanup.defaultScope", "大文件范围：下载、桌面、文稿、影片、图片和音乐；自选目录需位于个人文件夹内，且不能是 Library。"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(L("cleanup.settingsHint", "修改扫描设置后，点击重新扫描生效；名称、类别与来源筛选会立即生效。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(store.busy)
            HStack { Spacer(); Button(L("button.done", "完成")) { showsSettings = false } }
        }.padding(18).frame(width: 540)
    }
    private var summary: some View {
        HStack(spacing: 14) {
            metric(L("cleanup.scanned", "已扫描文件占用（估算）"), FileItem.formatSize(store.result.scannedBytes))
            metric(L("cleanup.candidates", "全部候选"), "\(store.result.files.count) · \(FileItem.formatSize(store.totalBytes))")
            metric(L("cleanup.filtered", "筛选结果"), "\(store.display.filtered.count) · \(FileItem.formatSize(store.display.bytes))")
            metric(L("cleanup.selected", "已选文件"), "\(store.selection.count) · \(FileItem.formatSize(store.selectedBytes))")
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }
    private var filters: some View {
        HStack {
            TextField(L("cleanup.search", "按文件名或路径筛选"), text: $store.search).textFieldStyle(.roundedBorder)
            Picker(L("inspector.type", "类型"), selection: $store.category) {
                Text(L("wechat.all", "全部类型")).tag("all")
                ForEach(store.availableKinds) { Text($0.title).tag($0.rawValue) }
            }.labelsHidden().frame(width: 120)
            Picker(L("cleanup.owner", "应用 / 来源"), selection: $store.owner) {
                Text(L("cleanup.allOwners", "全部应用 / 来源")).tag("all")
                ForEach(store.owners, id: \.self) { Text(store.ownerTitle($0)).tag($0) }
            }.labelsHidden().frame(width: 170)
            Picker(L("wechat.sort", "排序"), selection: $store.sort) {
                Text(L("sort.size", "按大小")).tag("size")
                Text(L("sort.name", "按名称")).tag("name")
                Text(L("cleanup.oldest", "最早修改优先")).tag("date")
            }.labelsHidden().frame(width: 125)
        }.disabled(store.busy)
    }
    private var files: some View {
        Table(of: StorageCleanupFile.self, selection: $store.selection) {
            TableColumn(L("column.name", "名称")) { file in
                HStack(spacing: 6) { Image(systemName: "doc").foregroundStyle(.secondary); Text(file.name).lineLimit(1) }.help(file.url.path)
            }.width(min: 140, ideal: 220)
            TableColumn(L("inspector.type", "类型")) { Text($0.rule.kind.title) }.width(min: 65, ideal: 80)
            TableColumn(L("cleanup.owner", "应用 / 来源")) { Text(store.displayOwner(for: $0)).lineLimit(1) }.width(min: 100, ideal: 140)
            TableColumn(L("column.size", "大小")) { Text(FileItem.formatSize($0.size)) }.width(min: 70, ideal: 85)
            TableColumn(L("cleanup.allocated", "磁盘占用")) { Text(FileItem.formatSize($0.allocated)) }.width(min: 70, ideal: 85)
            TableColumn(L("wechat.location", "所在目录")) { file in
                Button { model.openContainingFolder(of: file.url) } label: {
                    Text(file.url.deletingLastPathComponent().path).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.link)
            }.width(min: 130, ideal: 200)
        } rows: {
            ForEach(store.display.rows) { TableRow($0) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let file = store.result.files.first(where: { ids.contains($0.id) }) {
                Button(L("action.open", "打开")) { NSWorkspace.shared.open(file.url) }
                Button(L("action.quickLook", "快速查看")) { QuickLookService.shared.show([file.url]) }
                Button(L("action.openContainingFolder", "打开所在文件夹")) { model.openContainingFolder(of: file.url) }
                Button(L("action.copyPath", "复制完整路径")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.url.path, forType: .string)
                }
                Divider()
                Button(L("cleanup.ignoreFile", "忽略此文件")) { store.ignore(file.url) }
                Button(L("cleanup.ignoreFolder", "忽略所在文件夹")) { store.ignore(file.url.deletingLastPathComponent()) }
                Divider()
                Button(L("action.moveToTrash", "移到废纸篓"), role: .destructive) { store.requestTrash(ids) }.disabled(store.busy)
            }
        } primaryAction: { ids in
            if let file = store.result.files.first(where: { ids.contains($0.id) }) { NSWorkspace.shared.open(file.url) }
        }
        .background(TableDoubleClickInstaller { table in
            TableDiagnostics.installDoubleClick(on: table) { row in
                guard !store.busy, store.display.rows.indices.contains(row),
                      let item = FileItem(url: store.display.rows[row].url, resourceKeys: FileSystemService.resourceKeys, showHidden: true) else { return }
                model.activate(item)
            }
        }.frame(width: 0, height: 0))
        .disabled(store.busy)
        .overlay {
            if !store.busy && store.display.filtered.isEmpty {
                Text(store.hasScanned ? L("cleanup.empty", "当前范围内没有符合条件的文件，可调整筛选或扫描设置。") : L("cleanup.ready", "点击“开始扫描”查看空间占用和清理候选。"))
                    .font(.callout).foregroundStyle(.secondary).padding().allowsHitTesting(false)
            }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(L("wechat.selectAll", "全选筛选结果")) { store.selectAll() }.disabled(store.busy)
                Button(L("wechat.clearSelection", "清除选择")) { store.selection = [] }.disabled(store.busy)
                Spacer()
                Button { store.rebuild(page: store.display.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(store.display.page == 0)
                Text("\(store.display.page + 1) / \(store.display.pages)").font(.caption).monospacedDigit()
                Button { store.rebuild(page: store.display.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(store.display.page + 1 >= store.display.pages)
                Button(L("action.moveToTrash", "移到废纸篓"), role: .destructive) { store.requestTrash() }.disabled(store.busy || store.selection.isEmpty)
            }
            Text(store.isScanning ? L("cleanup.progress", "已检查 %d 项，发现 %d 个候选", store.progress.visited, store.progress.candidates)
                 : store.isCleaning ? L("cleanup.cleaning", "正在复查并清理第 %d 项…", store.cleaningIndex)
                 : L("cleanup.trashNote", "移到废纸篓不会立即释放磁盘空间；可用 ⌘Z 撤销成功的移动。占用受 APFS 共享块影响，仅作估算。"))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("cleanup.details", "扫描详情 / 忽略 / 历史")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = store.message { Text(message).font(.caption).textSelection(.enabled) }
                    Text(store.isBaidu ? L("software.baiduProtection", "仅处理明确下载目录中的文件，以及已识别的缓存和日志。不读取下载记录数据库；跳过未完成下载、数据库、凭据、隐藏文件、符号链接及硬链接。清理时检查百度网盘运行及文件占用状态，默认不勾选文件。") : store.softwareMode ? L("software.protection", "仅处理当前软件的缓存和日志。跳过运行中的应用、数据库、凭据、持久数据、受保护缓存、符号链接及硬链接；无法确认安全状态的项目会保留。") : L("cleanup.protection", "清理前检查应用运行和文件占用状态，跳过数据库、凭据、受保护缓存、符号链接及硬链接；无法确认安全状态的文件会保留。附件和下载文件是个人资料，请核对后再清理。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("cleanup.skippedOwners", "已跳过 %d 个运行中应用的扫描位置", store.result.skippedRunning)).font(.caption)
                    if !store.softwareMode {
                    Text(L("cleanup.distribution", "已扫描的大文件目录范围占用")).font(.subheadline.bold())
                    ForEach(store.result.folders.prefix(12)) { usage in
                        HStack { Button(usage.url.lastPathComponent) {
                            if let manager = model.tabManager { manager.newTab(startDirectory: usage.url) }
                            else { model.selectFolder(usage.url) }
                        }; Spacer(); Text(FileItem.formatSize(usage.bytes)) }.font(.caption)
                    }
                    Button(L("cleanup.defaultFolders", "恢复默认大文件扫描范围")) { store.useDefaultFolders() }.disabled(store.busy)
                    }
                    if !store.result.inaccessible.isEmpty { Text(store.result.inaccessible.joined(separator: "\n")).font(.caption2).textSelection(.enabled) }
                    Divider()
                    Text(L("cleanup.ignored", "忽略列表")).font(.subheadline.bold())
                    ForEach(store.ignored, id: \.path) { url in
                        HStack { Text(url.path).lineLimit(2).truncationMode(.middle); Spacer(); Button(L("cleanup.unignore", "取消忽略")) { store.removeIgnore(url) }.disabled(store.busy) }.font(.caption)
                    }
                    Divider()
                    Text(L("cleanup.history", "最近清理记录（仅本机）")).font(.subheadline.bold())
                    ForEach(store.history) { entry in
                        Text("\(entry.softwareName.map { $0 + " · " } ?? "")\(FileItem.formatDate(entry.date)) · \(entry.count) · \(FileItem.formatSize(entry.bytes)) · \(entry.failures) \(L("cleanup.skipped", "项跳过 / 失败"))\(entry.cancelled ? " · " + L("button.cancel", "取消") : "")").font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 520)
            HStack { Spacer(); Button(L("button.done", "完成")) { showsDetails = false } }
        }.padding(18).frame(width: 560)
    }
}
