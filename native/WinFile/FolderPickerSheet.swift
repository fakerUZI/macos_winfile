import SwiftUI

struct FolderPickerSheet: View {
    @ObservedObject private var localization = Localization.shared
    @StateObject private var browser: FolderPickerModel
    @Environment(\.dismiss) private var dismiss
    let onChoose: ([URL]) -> SidebarFolderAddition

    init(initialDirectory: URL? = nil, onChoose: @escaping ([URL]) -> SidebarFolderAddition) {
        _browser = StateObject(wrappedValue: FolderPickerModel(initialDirectory: initialDirectory))
        self.onChoose = onChoose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("folderPicker.title", "添加到个人收藏")).font(.headline)
            Text(L("folderPicker.hint", "双击进入文件夹，按住 ⌘ 可多选；也可直接添加当前文件夹。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { browser.navigate(to: browser.directory.deletingLastPathComponent()) } label: {
                    Image(systemName: "arrow.up")
                }
                .help(L("action.up", "向上"))
                .disabled(browser.directory.path == "/" || browser.isLoading)
                Button { browser.navigate(to: FileSystemService.realHomeDirectory()) } label: {
                    Image(systemName: "house")
                }.help(L("view.home", "主页"))
                TextField(L("folderPicker.path", "输入文件夹路径"), text: $browser.pathText)
                    .textFieldStyle(.roundedBorder).onSubmit { browser.openPath() }
                    .accessibilityIdentifier("folderPicker.path")
                Button(L("folderPicker.go", "前往")) { browser.openPath() }
            }
            HStack {
                TextField(L("folderPicker.search", "筛选当前目录中的文件夹"), text: $browser.search)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("settings.showHidden", "显示隐藏文件"), isOn: $browser.showHidden)
                    .toggleStyle(.checkbox)
            }
            Table(browser.visibleFolders.map { FolderPickerEntry(url: $0) }, selection: $browser.selectedPaths) {
                TableColumn(L("column.name", "名称")) { entry in
                    Label(entry.url.lastPathComponent, systemImage: "folder.fill")
                        .foregroundStyle(Color.accentColor).help(entry.url.path)
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
            .disabled(browser.isLoading)
            .onChange(of: browser.search) { _ in
                browser.selectedPaths.formIntersection(Set(browser.visibleFolders.map(\.path)))
            }
            if let error = browser.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Text((browser.directory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("button.cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(browser.selectedPaths.isEmpty ? L("folderPicker.addCurrent", "添加当前文件夹")
                       : L("folderPicker.addSelected", "添加 %d 个文件夹", browser.candidates.count)) {
                    let result = onChoose(browser.candidates)
                    if result.rejectedCount > 0 { browser.errorMessage = result.statusMessage }
                    else { dismiss() }
                }
                .disabled(browser.isLoading || browser.candidates.isEmpty)
            }
        }
        .padding(18).frame(width: 700, height: 490)
        .onAppear { browser.navigate(to: browser.directory) }
        .onDisappear { browser.cancelLoading() }
    }
}

private struct FolderPickerEntry: Identifiable {
    let url: URL
    var id: String { url.path }
}
