import AppKit
import SwiftUI

struct AdvancedSearchSheet: View {
    let model: BrowserModel
    @StateObject private var search = FileSearchModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool
    @State private var root: URL
    @State private var query: String
    @State private var minimum: String
    @State private var maximum: String
    @State private var useStart: Bool
    @State private var useEnd: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var kind = "all"
    @State private var category = "all"
    @State private var extensions = ""
    @State private var recursive = true
    @State private var showHidden = false
    @State private var choosingScope = false
    @State private var selectedID: String?
    @State private var sortField = SortField.name
    @State private var ascending = true

    init(model: BrowserModel, initialQuery: String? = nil) {
        self.model = model
        _root = State(initialValue: model.currentDirectory.flatMap { $0.isFileURL ? $0 : nil } ?? FileSystemService.realHomeDirectory())
        _query = State(initialValue: initialQuery ?? model.searchQuery)
        let criteria = model.searchCriteria
        _minimum = State(initialValue: criteria.minimumBytes.map { String(Double($0) / 1048576) } ?? "")
        _maximum = State(initialValue: criteria.maximumBytes.map { String(Double($0) / 1048576) } ?? "")
        _useStart = State(initialValue: criteria.modifiedAfter != nil)
        _useEnd = State(initialValue: criteria.modifiedBefore != nil)
        _start = State(initialValue: criteria.modifiedAfter ?? Date())
        _end = State(initialValue: criteria.modifiedBefore ?? Date())
        _kind = State(initialValue: criteria.foldersOnly.map { $0 ? "folders" : "files" } ?? "all")
        _category = State(initialValue: criteria.category?.rawValue ?? "all")
        _extensions = State(initialValue: (criteria.extensions ?? []).joined(separator: ", "))
        _showHidden = State(initialValue: model.showHidden)
    }

    private func bytes(_ text: String) -> Int64? {
        guard let number = Double(text), number.isFinite, number >= 0,
              number < Double(Int64.max) / 1048576 else { return nil }
        return Int64(number * 1048576)
    }
    private var request: FileSearchRequest {
        FileSearchRequest(root: root, query: query, criteria: FileSearchCriteria(
            minimumBytes: kind == "folders" ? nil : bytes(minimum), maximumBytes: kind == "folders" ? nil : bytes(maximum),
            modifiedAfter: useStart ? Calendar.current.startOfDay(for: start) : nil,
            modifiedBefore: useEnd ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))?.addingTimeInterval(-0.001) : nil,
            foldersOnly: kind == "all" ? nil : kind == "folders",
            category: kind == "folders" ? nil : FileCategory(rawValue: category),
            extensions: kind == "folders" ? nil : FileSearchCriteria.parseExtensions(extensions)),
            recursive: recursive, showHidden: showHidden)
    }
    private var valid: Bool {
        (kind == "folders" || ((minimum.isEmpty || bytes(minimum) != nil) && (maximum.isEmpty || bytes(maximum) != nil)))
            && request.isValid
    }
    private var results: [FileItem] { FileSystemService.sort(search.report.items, field: sortField, ascending: ascending) }
    private var selected: FileItem? { search.report.items.first { $0.id == selectedID } }
    private var changed: Bool { search.request != nil && search.request != request }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("search.windowTitle", "搜索文件"), systemImage: "magnifyingglass").font(.title2.bold())
                Spacer()
                Text("WinFile").foregroundStyle(.secondary)
            }
            scopeControls
            queryControls
            filterControls
            if (kind != "folders" && ((!minimum.isEmpty && bytes(minimum) == nil) || (!maximum.isEmpty && bytes(maximum) == nil))) || !request.criteria.isValid {
                Text(L("search.invalidRange", "请填写有效的非负大小，并确保起始大小和日期不晚于结束值。"))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(L("search.rulesHint", "条件同时满足；仅搜索文件名，不读取文件内容。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if search.isSearching {
                    ProgressView().controlSize(.small)
                    Button(L("search.stop", "停止搜索")) { search.stop() }
                } else {
                    Button(L("search.reset", "重置条件")) { reset() }
                    Button(L("search.start", "搜索")) { runSearch() }
                        .keyboardShortcut(.defaultAction).disabled(!valid)
                        .accessibilityIdentifier("search.start")
                }
            }
            Divider()
            resultsHeader
            resultTable
            footer
        }
        .padding(20).frame(width: 900, height: 660).textFieldStyle(.roundedBorder)
        .onAppear { queryFocused = true; if search.request == nil && valid { runSearch() } }
        .onDisappear { search.close() }
        .sheet(isPresented: $choosingScope) {
            FolderPickerSheet(initialDirectory: root, title: L("search.chooseScope", "选择搜索范围")) { url in
                root = url; return nil
            }
        }
    }

    private var scopeControls: some View {
        HStack {
            Text(L("search.scope", "搜索范围"))
            Text(FileSystemService.abbreviate(root)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).help(root.path).textSelection(.enabled)
            Spacer(minLength: 4)
            Menu(L("search.quickScope", "常用位置")) {
                Button(L("view.home", "个人文件夹")) { root = FileSystemService.realHomeDirectory() }
                Button(L("place.downloads", "下载")) { root = FileSystemService.realHomeDirectory().appendingPathComponent("Downloads") }
                if let directory = model.currentDirectory, directory.isFileURL {
                    Button(L("search.currentScope", "当前文件夹")) { root = directory }
                }
            }.fixedSize()
            Button(L("search.chooseScope", "选择搜索范围")) { choosingScope = true }
                .accessibilityIdentifier("search.scope")
        }
    }

    private var queryControls: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("search.nameHint", "输入文件名或部分名称，也可只使用筛选条件"), text: $query)
                .focused($queryFocused).onSubmit { if valid && !search.isSearching { runSearch() } }
                .accessibilityIdentifier("search.query")
        }
    }

    private var filterControls: some View {
        VStack(spacing: 10) {
            HStack {
                Picker(L("search.entryKind", "对象"), selection: $kind) {
                    Text(L("search.all", "全部")).tag("all")
                    Text(L("search.files", "文件")).tag("files")
                    Text(L("search.folders", "文件夹")).tag("folders")
                }.frame(width: 180)
                Picker(L("column.type", "类型"), selection: $category) {
                    Text(L("search.allTypes", "全部类型")).tag("all")
                    ForEach(FileCategory.allCases.filter { $0 != .folder }) { Text($0.localizedName).tag($0.rawValue) }
                }.frame(width: 200).disabled(kind == "folders")
                TextField(L("search.extensions", "扩展名，如 pdf, zip, jpg"), text: $extensions)
                    .disabled(kind == "folders").accessibilityIdentifier("search.extensions")
            }
            HStack {
                TextField(L("search.minimumMB", "最小大小（MB，可留空）"), text: $minimum).disabled(kind == "folders")
                TextField(L("search.maximumMB", "最大大小（MB，可留空）"), text: $maximum).disabled(kind == "folders")
                Toggle(L("search.recursive", "包含子文件夹"), isOn: $recursive)
                Toggle(L("settings.showHidden", "显示隐藏文件"), isOn: $showHidden)
            }.toggleStyle(.checkbox)
            HStack {
                Toggle(L("search.after", "修改日期从"), isOn: $useStart)
                DatePicker("", selection: $start, displayedComponents: .date).labelsHidden().disabled(!useStart)
                Toggle(L("search.before", "修改日期至"), isOn: $useEnd)
                DatePicker("", selection: $end, displayedComponents: .date).labelsHidden().disabled(!useEnd)
                Spacer()
            }.toggleStyle(.checkbox)
        }
    }

    private var resultsHeader: some View {
        HStack {
            Text(search.isSearching ? L("search.scanning", "正在扫描，已检查 %d 项…", search.visited)
                 : L("search.found", "%d 个结果 · 已检查 %d 项", search.report.items.count, search.visited))
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Picker(L("search.sort", "排序"), selection: $sortField) {
                Text(L("column.name", "名称")).tag(SortField.name)
                Text(L("column.size", "大小")).tag(SortField.size)
                Text(L("column.modified", "修改日期")).tag(SortField.modified)
            }.frame(width: 170)
            Button { ascending.toggle() } label: { Image(systemName: ascending ? "arrow.up" : "arrow.down") }
                .help(L("search.reverseSort", "反转排序"))
        }
    }

    private var resultTable: some View {
        Table(results, selection: $selectedID) {
            TableColumn(L("column.name", "名称")) { item in
                Label(item.name, systemImage: item.category.symbol).lineLimit(1).help(item.url.path)
            }.width(min: 200, ideal: 260)
            TableColumn(L("column.size", "大小")) { Text($0.sizeText).foregroundStyle(.secondary) }.width(85)
            TableColumn(L("column.type", "类型")) { Text($0.category.localizedName) }.width(90)
            TableColumn(L("search.location", "所在文件夹")) {
                Text(FileSystemService.abbreviate($0.url.deletingLastPathComponent()))
                    .lineLimit(1).truncationMode(.middle).help($0.url.deletingLastPathComponent().path)
            }
        }
        .accessibilityIdentifier("search.results")
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = search.report.items.first(where: { ids.contains($0.id) }) {
                Button(L("action.open", "打开")) { open(item) }
                Button(L("search.locate", "在新页签中打开所在文件夹")) { locate(item) }
                Divider()
                Button(L("action.copyPath", "复制完整路径")) { copyPath(item) }
            }
        } primaryAction: { ids in
            if let item = search.report.items.first(where: { ids.contains($0.id) }) { open(item) }
        }
        .background(TableDoubleClickInstaller { table in
            TableDiagnostics.installDoubleClick(on: table) { row in
                let items = results
                guard items.indices.contains(row) else { return }
                open(items[row])
            }
        }.frame(width: 0, height: 0))
        .overlay {
            if search.report.items.isEmpty {
                Text(search.isSearching ? L("search.searching", "正在搜索…") : search.request == nil
                     ? L("search.ready", "选择范围，输入名称或筛选条件后开始搜索。")
                     : L("search.noMatches", "没有找到匹配项，可调整条件或搜索范围。"))
                    .foregroundStyle(.secondary).allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if changed { Text(L("search.changed", "条件已更改，点击搜索以更新结果。")).font(.caption).foregroundStyle(.orange) }
            if let error = search.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if search.report.cancelled { Text(L("search.stopped", "搜索已停止，显示已找到的结果。")).font(.caption).foregroundStyle(.secondary) }
            if search.report.limitReached || search.report.visitLimitReached {
                Text(L("search.limited", "已达到本轮扫描上限，结果不完整。可扩大扫描，或缩小范围、增加条件。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("action.open", "打开")) { if let selected { open(selected) } }.disabled(selected == nil)
                Button(L("search.locate", "在新页签中打开所在文件夹")) { if let selected { locate(selected) } }.disabled(selected == nil)
                Spacer()
                if search.canExpand && !changed {
                    Button(L("search.expand", "扩大扫描")) { selectedID = nil; search.expand() }
                }
                Button(L("search.close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }
    private func runSearch() { selectedID = nil; search.search(request) }
    private func reset() {
        query = ""; minimum = ""; maximum = ""; useStart = false; useEnd = false
        kind = "all"; category = "all"; extensions = ""; recursive = true; showHidden = false
    }
    private func copyPath(_ item: FileItem) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string)
    }
    private func open(_ item: FileItem) {
        if item.isDirectory && !(item.isBundle && item.url.pathExtension.lowercased() == "app") {
            dismiss()
            DispatchQueue.main.async { model.tabManager?.newTab(startDirectory: item.url) }
        } else { model.activate(item) }
    }
    private func locate(_ item: FileItem) {
        dismiss()
        DispatchQueue.main.async { model.openContainingFolder(of: item.url, inNewTab: true) }
    }
}
