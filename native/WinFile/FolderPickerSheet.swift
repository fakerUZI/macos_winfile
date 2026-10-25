import SwiftUI

struct FolderPickerSheet: View {
    @ObservedObject private var localization = Localization.shared
    @StateObject private var browser: FolderPickerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @FocusState private var newFolderNameFocused: Bool
    private let onChoose: ([URL]) -> String?
    private let pickerTitle: String
    private let singleFolder: Bool
    private var opensFolders = false

    init(initialDirectory: URL? = nil, onOpen: @escaping ([URL]) -> Void) {
        _browser = StateObject(wrappedValue: FolderPickerModel(initialDirectory: initialDirectory))
        pickerTitle = L("panel.open.message", "选择要打开的文件夹")
        singleFolder = false
        opensFolders = true
        onChoose = { urls in onOpen(urls); return nil }
    }

    init(initialDirectory: URL? = nil, onChoose: @escaping ([URL]) -> SidebarFolderAddition) {
        _browser = StateObject(wrappedValue: FolderPickerModel(initialDirectory: initialDirectory))
        pickerTitle = L("folderPicker.title", "添加到个人收藏")
        singleFolder = false
        self.onChoose = { urls in
            let result = onChoose(urls)
            return result.rejectedCount > 0 ? result.statusMessage : nil
        }
    }

    init(initialDirectory: URL? = nil, title: String, onSelect: @escaping (URL) -> String?) {
        _browser = StateObject(wrappedValue: FolderPickerModel(initialDirectory: initialDirectory))
        pickerTitle = title
        singleFolder = true
        self.onChoose = { urls in
            guard urls.count == 1, let url = urls.first else { return L("cleanup.chooseOne", "请选择一个文件夹。") }
            return onSelect(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pickerTitle).font(.headline)
            Text(opensFolders ? L("folderPicker.openHint", "双击进入目录，按住 ⌘ 可多选；选中的文件夹将在新页签中打开。") : singleFolder ? L("cleanup.folderHint", "双击进入目录，选择一个文件夹或使用当前文件夹。") : L("folderPicker.hint", "双击进入文件夹，按住 ⌘ 可多选；也可直接添加当前文件夹。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { browser.navigate(to: browser.directory.deletingLastPathComponent()) } label: {
                    Image(systemName: "arrow.up")
                }
                .help(L("action.up", "向上"))
                .disabled(browser.directory.path == "/" || browser.isWorking)
                Button { browser.navigate(to: FileSystemService.realHomeDirectory()) } label: {
                    Image(systemName: "house")
                }.help(L("view.home", "主页"))
                    .disabled(browser.isWorking)
                TextField(L("folderPicker.path", "输入文件夹路径"), text: $browser.pathText)
                    .textFieldStyle(.roundedBorder).onSubmit { browser.openPath() }
                    .accessibilityIdentifier("folderPicker.path")
                Button(L("folderPicker.go", "前往")) { browser.openPath() }
            }.disabled(browser.isCreating)
            HStack {
                TextField(L("folderPicker.search", "筛选当前目录中的文件夹"), text: $browser.search)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("settings.showHidden", "显示隐藏文件"), isOn: $browser.showHidden)
                    .toggleStyle(.checkbox)
            }.disabled(browser.isCreating)
            Table(browser.visibleFolders.map { FolderPickerEntry(url: $0) }, selection: $browser.selectedPaths) {
                TableColumn(L("column.name", "名称")) { entry in
                    Label(entry.url.lastPathComponent, systemImage: "folder.fill")
                        .help(entry.url.path)
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let path = ids.first { browser.navigate(to: URL(fileURLWithPath: path)) }
            }
            .background(TableDoubleClickInstaller { table in
                TableDiagnostics.installDoubleClick(on: table) { row in
                    let folders = browser.visibleFolders
                    guard folders.indices.contains(row) else { return }
                    browser.navigate(to: folders[row])
                }
            }.frame(width: 0, height: 0))
            .overlay {
                if browser.isLoading { ProgressView() }
                else if browser.visibleFolders.isEmpty {
                    Text(L("folderPicker.empty", "没有可选择的子文件夹，可添加当前文件夹。"))
                        .font(.caption).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .disabled(browser.isWorking)
            .onChange(of: browser.search) { _ in
                browser.selectedPaths.formIntersection(Set(browser.visibleFolders.map(\.path)))
            }
            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button {
                    newFolderName = WLocalizedString("default.newFolderName", comment: "新建文件夹")
                    browser.errorMessage = nil
                    showingNewFolder = true
                } label: {
                    Label(L("folderPicker.newFolder", "新建文件夹…"), systemImage: "folder.badge.plus")
                }
                .disabled(!browser.canCreateFolder)
                .accessibilityIdentifier("folderPicker.newFolder")
                Text((browser.directory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("button.cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(browser.isCreating)
                Button(opensFolders ? (browser.selectedPaths.isEmpty ? L("folderPicker.openCurrent", "打开当前文件夹") : L("folderPicker.openSelected", "打开 %d 个文件夹", browser.candidates.count)) : singleFolder ? L("cleanup.choose", "选择此文件夹") : browser.selectedPaths.isEmpty ? L("folderPicker.addCurrent", "添加当前文件夹")
                       : L("folderPicker.addSelected", "添加 %d 个文件夹", browser.candidates.count)) {
                    if let error = onChoose(browser.candidates) { browser.errorMessage = error }
                    else { dismiss() }
                }
                .disabled(browser.isWorking || !browser.canChooseDirectory || browser.candidates.isEmpty)
                .accessibilityIdentifier("folderPicker.choose")
            }
        }
        .padding(18).frame(width: 700, height: 490)
        .onAppear { browser.navigate(to: browser.directory) }
        .onDisappear { browser.cancelLoading() }
        .sheet(isPresented: $showingNewFolder) { newFolderSheet }
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("dialog.newFolder.title", "新建文件夹")).font(.headline)
            Text(L("folderPicker.newFolderHint", "创建后将进入新文件夹，可将它选为保存位置。"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L("column.name", "名称"), text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .focused($newFolderNameFocused)
                .disabled(browser.isCreating)
                .accessibilityIdentifier("folderPicker.newFolder.name")
            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if browser.isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("button.cancel", "取消")) { showingNewFolder = false }
                    .keyboardShortcut(.cancelAction).disabled(browser.isCreating)
                Button(L("folderPicker.create", "创建")) {
                    Task { @MainActor in
                        if await browser.createFolder(named: newFolderName) { showingNewFolder = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(browser.isWorking || newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("folderPicker.newFolder.confirm")
            }
        }
        .padding(20).frame(width: 390)
        .interactiveDismissDisabled(browser.isCreating)
        .onAppear { newFolderNameFocused = true }
    }
}

private struct FolderPickerEntry: Identifiable {
    let url: URL
    var id: String { url.path }
}
