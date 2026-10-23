import AppKit
import Quartz
import SwiftUI

struct ArchivePreviewSheet: View {
    let request: ArchivePreviewRequest
    @ObservedObject var browser: BrowserModel
    @StateObject private var model: ArchivePreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Int?
    @State private var password = ""
    @State private var choosingDestination = false

    init(request: ArchivePreviewRequest, browser: BrowserModel) {
        self.request = request
        self.browser = browser
        _model = StateObject(wrappedValue: ArchivePreviewModel(archive: request.archive))
    }

    private var entries: [ArchiveMember] {
        (model.contents?.entries ?? []).filter { query.isEmpty || $0.path.localizedStandardContains(query) }
    }
    private var selected: ArchiveMember? { model.contents?.entries.first { $0.id == selection } }
    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("archive.preview.title", "预览压缩包"), systemImage: "archivebox").font(.title2.bold())
                Spacer()
                if model.isLoading || model.isPreparing { ProgressView().controlSize(.small) }
                Button(L("button.close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(request.archive.lastPathComponent).font(.headline).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).help(request.archive.path)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("archive.preview.filter", "筛选包内文件名或路径"), text: $query)
                    .accessibilityIdentifier("archive.preview.filter")
            }.textFieldStyle(.roundedBorder)
            if let contents = model.contents {
                Text(L("archive.preview.summary", "%d 个项目 · 已知原始大小 %@", contents.entries.count, bytes(contents.totalSize)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            memberTable
            if let preview = model.preview {
                HStack {
                    Text(preview.url.lastPathComponent).font(.caption).lineLimit(1)
                    Spacer()
                    Button(L("archive.preview.closeFile", "关闭文件预览")) { model.clearPreview() }
                }
                ArchiveQuickLookView(url: preview.url).frame(height: 200)
            }
            if model.needsPassword { passwordControls }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
            }
            Text(L("archive.preview.hint", "列表不解出普通压缩包；查看文件仅临时解出所选项（最大 64 MiB），不打开外部应用，关闭后删除。压缩 TAR 预览需临时展开中间归档（最大 512 MiB）。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("archive.preview.file", "查看所选文件")) { showSelected() }
                    .disabled(selected?.canPreview != true || model.isPreparing || model.needsPassword)
                if model.isPreparing { Button(L("button.cancel", "取消")) { model.clearPreview() } }
                Spacer()
                Menu(L("action.extract", "解压")) {
                    Button(L("action.extractHere", "解压到当前文件夹")) { extract(to: request.destination) }
                    Button(L("action.extractFolder", "解压到独立文件夹")) { extract(to: request.destination, createFolder: true) }
                    Button(L("action.extractTo", "解压到…")) { choosingDestination = true }
                }.fixedSize().disabled(model.contents == nil || !browser.canMutateFiles || model.isLoading || model.isPreparing)
            }
        }
        .padding(20).frame(width: 900, height: 700)
        .onAppear { model.load() }
        .onDisappear { model.close(); password = "" }
        .onChange(of: selection) { _ in model.clearPreview(); password = "" }
        .onChange(of: query) { _ in selection = nil }
        .sheet(isPresented: $choosingDestination) {
            FolderPickerSheet(initialDirectory: request.destination, title: L("archive.chooseDestination", "选择解压文件的保存位置")) { directory in
                extract(to: directory)
                return nil
            }
        }
    }

    private var memberTable: some View {
        Table(entries, selection: $selection) {
            TableColumn(L("archive.preview.path", "包内路径")) { item in
                Label(item.path, systemImage: item.isLink ? "link" : item.isDirectory ? "folder" : "doc")
                    .lineLimit(1).truncationMode(.middle).help(item.path)
            }.width(min: 260, ideal: 450)
            TableColumn(L("column.size", "大小")) { Text($0.isDirectory ? "—" : bytes($0.size)) }.width(90)
            TableColumn(L("archive.preview.packed", "压缩后")) { Text(bytes($0.packedSize)) }.width(90)
            TableColumn(L("archive.preview.method", "压缩方式")) { item in
                HStack {
                    if item.encrypted { Image(systemName: "lock.fill").accessibilityLabel(L("archive.preview.encrypted", "已加密")) }
                    Text(item.method.isEmpty ? "—" : item.method).lineLimit(1).help(item.method)
                }
            }.width(140)
        }
        .accessibilityIdentifier("archive.preview.entries")
        .background(TableDoubleClickInstaller { table in
            TableDiagnostics.installDoubleClick(on: table) { row in
                let visible = entries
                guard visible.indices.contains(row), visible[row].canPreview else { return }
                selection = visible[row].id
                // Selection changes clear the old preview before starting this request.
                DispatchQueue.main.async { model.show(visible[row]) }
            }
        }.frame(width: 0, height: 0))
        .overlay {
            if entries.isEmpty {
                Text(model.isLoading ? L("archive.preview.loading", "正在读取压缩包目录…") : model.needsPassword ? L("archive.error.passwordRequired", "此压缩包需要密码。") : L("archive.preview.empty", "没有可显示的项目"))
                    .foregroundStyle(.secondary).allowsHitTesting(false)
            }
        }
    }

    private var passwordControls: some View {
        HStack {
            SecureField(L("archive.password.placeholder", "密码（仅用于本次解压）"), text: $password).textFieldStyle(.roundedBorder)
                .onSubmit { unlock() }
            Button(L("archive.preview.unlock", "解锁预览")) { unlock() }.disabled(password.isEmpty)
        }
    }

    private func unlock() {
        let secret = password
        password = ""
        if model.contents == nil { model.load(password: secret) }
        else if let selected { model.show(selected, password: secret) }
    }

    private func showSelected() {
        guard let selected, selected.canPreview else { return }
        model.show(selected)
    }

    private func extract(to directory: URL, createFolder: Bool = false) {
        dismiss()
        let archive = request.archive
        DispatchQueue.main.async { browser.extractArchives([archive], to: directory, createFolder: createFolder) }
    }
}

private struct ArchiveQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}
