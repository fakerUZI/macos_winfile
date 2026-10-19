import AppKit
import SwiftUI

struct WeChatCleanupView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var store: WeChatCleanupModel
    @ObservedObject var model: BrowserModel
    @Binding var dialog: DialogKind?
    @State private var showAdvancedFilters = false
    @State private var usageByMonth = false
    @State private var showScanDetails = false

    init(model: BrowserModel, dialog: Binding<DialogKind?>) {
        self.model = model
        self.store = model.weChatCleanup
        self._dialog = dialog
    }

    private var operationInProgress: Bool { store.isScanning || store.isCleaning || model.isBusy || model.archiveProgress != nil || model.fileTransferProgress != nil }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 500
            VStack(alignment: .leading, spacing: compact ? 6 : 12) {
                header
                usageSummary(compact: compact)
                filters
                HStack {
                    Button { showScanDetails.toggle() } label: {
                        Label(L("wechat.scanDetails", "扫描详情与占用分布"), systemImage: store.result.inaccessible.isEmpty ? "chart.bar.xaxis" : "exclamationmark.triangle")
                    }.buttonStyle(.link)
                    .popover(isPresented: $showScanDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            ScrollView { scanDetails }.frame(maxHeight: 500)
                            HStack { Spacer(); Button(L("button.done", "完成")) { showScanDetails = false } }
                        }.padding(16).frame(width: 540)
                    }
                    Spacer()
                    if store.isScanning {
                        Text(L("wechat.scanProgress", "已发现 %d 项（%@），已检查 %d 个条目", store.scanProgress.files,
                               FileItem.formatSize(store.scanProgress.bytes), store.scanProgress.visited))
                            .lineLimit(1).foregroundStyle(.secondary)
                    }
                }.font(.caption)
                files.frame(minHeight: 100)
                footer
            }
            .controlSize(compact ? .small : .regular)
            .padding(compact ? 10 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { if !store.hasScanned { store.scan() } }
        .onChange(of: store.message) { if $0 != nil { showScanDetails = true } }
        .alert(L("wechat.confirmTitle", "将所选附件移到废纸篓？"), isPresented: $store.confirmsTrash) {
            Button(L("action.moveToTrash", "移到废纸篓"), role: .destructive) { store.clean(store.pendingTrashFiles) }
            Button(L("button.cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L("wechat.confirmMessage", "将清理 %d 个文件（%@）。这些附件可能无法在微信中再次打开。可从废纸篓恢复到原位置；建议先退出微信。", store.pendingTrashFiles.count,
                   FileItem.formatSize(store.pendingTrashFiles.reduce(0) { $0 + $1.size })))
        }
    }

    private var scanDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("wechat.explain", "扫描本机微信下载的聊天附件。清理后，对应附件可能无法在微信中打开；聊天数据库不会被清理。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("wechat.usage.scope", "仅统计已扫描的本机附件，不包含聊天数据库；清理后自动更新。"))
                .font(.caption).foregroundStyle(.secondary)
            roots
            usageAnalysis
            if store.isScanning { Text(store.scanProgress.currentPath).font(.caption).textSelection(.enabled) }
            if !store.result.inaccessible.isEmpty { accessHint }
            if let message = store.message { Text(message).font(.caption).textSelection(.enabled) }
            if !model.statusMessage.isEmpty { Text(model.statusMessage).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageSummary(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("wechat.usage.title", "当前附件占用")).font(compact ? .caption : .headline)
                Spacer()
                if let date = store.lastScanDate {
                    Text(L("wechat.lastScan", "最后扫描：%@", FileItem.formatDate(date))).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                usageCard(L("wechat.usage.total", "全部附件"),
                          bytes: store.isScanning ? store.scanProgress.bytes : store.totalSize,
                          count: store.isScanning ? store.scanProgress.files : store.result.files.count, compact: compact)
                usageCard(L("wechat.usage.filtered", "当前筛选"), bytes: store.matchingSize, count: store.matchingCount, compact: compact)
                usageCard(L("wechat.usage.selected", "已选附件"), bytes: store.selectedSize, count: store.selectedFiles.count, compact: compact)
            }
        }
    }

    private var usageAnalysis: some View {
        DisclosureGroup(L("wechat.usage.analysis", "占用分布（当前筛选）")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("wechat.usage.group", "分组"), selection: $usageByMonth) {
                    Text(L("inspector.type", "类型")).tag(false)
                    Text(L("wechat.month", "月份")).tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 240)
                let buckets = store.usageBuckets(byMonth: usageByMonth)
                let total = max(1, buckets.reduce(Int64(0)) { $0 + $1.bytes })
                ForEach(buckets) { bucket in
                    Button {
                        if usageByMonth { store.month = bucket.id } else { store.kind = bucket.id }
                    } label: {
                        HStack {
                            Text(bucket.title).frame(width: 110, alignment: .leading)
                            ProgressView(value: Double(bucket.bytes), total: Double(total))
                            Text(L("wechat.usage.bucket", "%@ · %d 项", FileItem.formatSize(bucket.bytes), bucket.count))
                                .monospacedDigit().frame(width: 150, alignment: .trailing)
                        }.font(.caption)
                    }.buttonStyle(.plain).help(L("wechat.usage.filter", "点击筛选此分组"))
                }
            }.padding(.top, 6).disabled(operationInProgress)
        }
    }

    private func usageCard(_ title: String, bytes: Int64, count: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(FileItem.formatSize(bytes)).font(compact ? .headline : .title3.weight(.semibold)).monospacedDigit()
            if !compact { Text(L("wechat.usage.count", "%d 个文件", count)).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 6 : 10)
        .help(L("wechat.usage.count", "%d 个文件", count))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack {
            Label(L("wechat.title", "微信文件清理"), systemImage: "bubble.left.and.bubble.right.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
            Spacer()
            if operationInProgress { ProgressView().controlSize(.small) }
            if store.isScanning {
                Button(L("button.cancel", "取消")) { store.cancelScan() }
            } else {
                Button(L("appData.rescan", "重新扫描")) { store.scan() }.disabled(operationInProgress)
            }
            Button(L("wechat.choose", "选择微信文件夹…")) { store.addFolder() }
                .disabled(operationInProgress)
        }
    }

    private var roots: some View {
        DisclosureGroup(L("wechat.sources", "扫描位置（%d 个自动发现，%d 个手动添加）",
                          store.result.roots.filter { !store.customRoots.contains($0) }.count, store.customRoots.count)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.result.roots.filter { !store.customRoots.contains($0) }, id: \.path) { root in
                        Text(root.path).font(.caption).textSelection(.enabled)
                    }
                    ForEach(store.customRoots, id: \.path) { root in
                        HStack {
                            Text(root.path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button(L("settings.folders.remove", "从列表移除")) { store.removeFolder(root) }
                                .disabled(operationInProgress)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 85)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L("wechat.search", "按文件名筛选"), text: $store.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100)
                Picker(L("inspector.type", "类型"), selection: $store.kind) {
                    Text(L("wechat.all", "全部类型")).tag("all")
                    ForEach(WeChatFileKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
                }.labelsHidden().frame(width: 110)
                Button {
                    showAdvancedFilters.toggle()
                } label: {
                    Label(store.advancedFilterCount == 0
                          ? L("wechat.filters.advanced", "高级筛选")
                          : L("wechat.filters.advancedCount", "高级筛选（%d）", store.advancedFilterCount),
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $showAdvancedFilters, arrowEdge: .bottom) { advancedFilters }
                .help(L("wechat.filters.advancedHint", "按账号、月份、来源、大小和修改时间筛选"))
            }
            if !store.activeFilters.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(store.activeFilters) { filter in
                                Button { store.clearFilter(filter) } label: {
                                    HStack(spacing: 4) {
                                        Text(store.filterTitle(filter)).lineLimit(1)
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }.padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(L("wechat.filters.remove", "移除此筛选：%@", store.filterTitle(filter)))
                                .accessibilityLabel(L("wechat.filters.remove", "移除此筛选：%@", store.filterTitle(filter)))
                            }
                        }
                    }.scrollIndicators(.hidden).frame(height: 28)
                    Button(L("wechat.filters.reset", "重置筛选")) { store.resetFilters() }
                }.font(.caption)
            }
        }.disabled(operationInProgress)
    }

    private var advancedFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("wechat.filters.advanced", "高级筛选")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text(L("wechat.account", "账号"))
                    Picker(L("wechat.account", "账号"), selection: $store.account) {
                        Text(L("wechat.allAccounts", "全部账号")).tag("all")
                        ForEach(store.accounts, id: \.self) { account in
                            Text(account == "custom" ? L("wechat.customAccount", "其它 / 自定义位置") : account).tag(account)
                        }
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.month", "月份"))
                    Picker(L("wechat.month", "月份"), selection: $store.month) {
                        Text(L("wechat.allMonths", "全部月份")).tag("all")
                        ForEach(store.months, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.source", "来源"))
                    Picker(L("wechat.source", "来源"), selection: $store.source) {
                        Text(L("wechat.allSources", "全部来源")).tag("all")
                        Text(L("wechat.attachments", "聊天附件")).tag("attachment")
                        Text(L("wechat.caches", "缓存 / 缩略图")).tag("cache")
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.minimumSize", "最小大小"))
                    Picker(L("wechat.minimumSize", "最小大小"), selection: $store.minimumMB) {
                        Text(L("wechat.anySize", "不限大小")).tag(0)
                        Text("10 MB").tag(10)
                        Text("100 MB").tag(100)
                        Text("1 GB").tag(1024)
                    }.labelsHidden()
                }
                GridRow {
                    Text(L("wechat.age", "修改时间"))
                    Picker(L("wechat.age", "修改时间"), selection: $store.olderThanDays) {
                        Text(L("wechat.anyTime", "不限时间")).tag(0)
                        ForEach([30, 90, 180], id: \.self) { days in
                            Text(L("wechat.days", "%d 天以前", days)).tag(days)
                        }
                    }.labelsHidden()
                }
            }
            HStack {
                Button(L("wechat.filters.reset", "重置筛选")) { store.resetFilters() }
                    .disabled(store.activeFilters.isEmpty)
                Spacer()
                Button(L("button.done", "完成")) { showAdvancedFilters = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 340).disabled(operationInProgress)
    }

    private var sortOrder: Binding<[KeyPathComparator<WeChatFile>]> {
        Binding(
            get: { [WeChatSortOrderBridge.comparator(for: store.sort, ascending: store.sortAscending)] },
            set: { value in
                guard let first = value.first, let field = WeChatSortOrderBridge.field(for: first) else { return }
                store.sort = field
                store.sortAscending = first.order == .forward
            }
        )
    }

    private var accessHint: some View {
        HStack(alignment: .top) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("wechat.access", "部分目录无法读取，结果可能不完整。可授予 WinFile 完整磁盘访问权限后重新扫描，或手动选择微信文件夹。"))
                    .font(.caption)
                DisclosureGroup(L("wechat.unreadable", "查看无法读取的位置")) {
                    ScrollView { Text(store.result.inaccessible.joined(separator: "\n")).font(.caption2).textSelection(.enabled) }
                        .frame(maxHeight: 65)
                }
            }
            Button(L("appData.openSettings", "打开系统设置")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var files: some View {
        Table(store.visibleFiles, selection: $store.selection, sortOrder: sortOrder) {
            TableColumn(L("column.name", "名称"), value: \WeChatFile.name, comparator: .localizedStandard) { file in
                HStack(spacing: 5) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(file.url.lastPathComponent).lineLimit(1).help(file.url.path)
                }
            }.width(min: 140, ideal: 240)
            TableColumn(L("inspector.type", "类型"), value: \WeChatFile.typeDescription, comparator: .localizedStandard) { file in Text(file.kind.title) }.width(min: 65, ideal: 85)
            TableColumn(L("column.size", "大小"), value: \WeChatFile.size) { file in Text(FileItem.formatSize(file.size)) }.width(min: 70, ideal: 90)
            TableColumn(L("column.modified", "修改日期"), value: \WeChatFile.modified) { file in Text(FileItem.formatDate(file.modified)) }.width(min: 120, ideal: 140)
            TableColumn(L("wechat.location", "所在目录"), value: \WeChatFile.parentPath, comparator: .localizedStandard) { file in
                Button { model.openContainingFolder(of: file.url) } label: {
                    Text(file.url.deletingLastPathComponent().path).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help(L("action.openContainingFolder", "打开所在文件夹") + "\n" + file.url.deletingLastPathComponent().path)
            }.width(min: 150, ideal: 240)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                let _ = store.selectForContextMenu(ids)
                FileItemContextMenu(engine: model.engine, model: model, dialog: $dialog,
                                    item: store.selectedFiles.first.map { FileItem(weChatFile: $0) })
            } else {
                Button(L("appData.rescan", "重新扫描")) { store.scan() }
                Button(L("wechat.selectAll", "全选筛选结果")) { model.selectAll() }
            }
        }
        .onDeleteCommand { model.deleteSelection() }
        .background(
            TableDoubleClickInstaller { table in
                TableColumnPreferences.install(on: table, kind: "wechat")
                TableDiagnostics.installDoubleClick(on: table) { row in
                    guard !operationInProgress, let item = store.itemForActivation(at: row) else { return }
                    model.activate(item)
                }
            }.frame(width: 0, height: 0)
        )
        .frame(minHeight: 0, maxHeight: .infinity)
        .layoutPriority(-1)
        .disabled(operationInProgress)
        .overlay {
            if store.matchingCount == 0 {
                Text(store.isScanning ? L("wechat.scanning", "正在扫描微信附件…")
                     : store.result.files.isEmpty ? L("wechat.empty", "未发现可清理的附件。可手动选择微信数据目录；无法读取的位置请检查访问权限。")
                     : L("wechat.noMatch", "没有符合筛选条件的文件。"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                    .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("wechat.summary", "共 %d 项（%@），筛选后 %d 项", store.result.files.count,
                   FileItem.formatSize(store.totalSize), store.matchingCount))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    if let file = store.selectedFiles.first { model.openContainingFolder(of: file.url) }
                } label: {
                    Label(L("action.openContainingFolder", "打开所在文件夹"), systemImage: "folder")
                }
                .disabled(store.selectedFiles.count != 1 || operationInProgress)
                Spacer()
                Button(L("wechat.selectAll", "全选筛选结果")) { store.selection = Set(store.visibleFiles.map(\.id)) }
                    .disabled(operationInProgress || store.visibleFiles.isEmpty)
                Button(L("wechat.trashSelection", "清理所选 %d 项（%@）", store.selectedFiles.count, FileItem.formatSize(store.selectedSize)), role: .destructive) {
                    store.requestTrash()
                }.disabled(store.selectedFiles.isEmpty || operationInProgress)
            }
        }
    }
}
