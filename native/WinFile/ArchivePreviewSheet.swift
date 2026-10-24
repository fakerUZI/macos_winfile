import AppKit
import Quartz
import SwiftUI

struct ArchivePreviewSheet: View {
    let request: ArchivePreviewRequest
    @ObservedObject var browser: BrowserModel
    @StateObject private var model: ArchivePreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var directory = ""
    @State private var selection: String?
    @State private var password = ""
    @State private var choosingDestination = false
    @State private var showsDetails = false
    @State private var showsPreview = false
    @State private var previewMember: ArchiveMember?

    init(request: ArchivePreviewRequest, browser: BrowserModel) {
        self.request = request
        self.browser = browser
        _model = StateObject(wrappedValue: ArchivePreviewModel(archive: request.archive))
    }

    private var entries: [ArchiveBrowserEntry] { model.directoryIndex.rows(in: directory, matching: query) }
    private var selected: ArchiveBrowserEntry? { entries.first { $0.id == selection } }
    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func bytes(_ value: Int64?) -> String {
        value.map { FileItem.formatSize($0) } ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            navigation
            GeometryReader { geometry in
                if showsPreview && geometry.size.width >= 900 {
                    HSplitView {
                        memberTable.frame(minWidth: 400, maxWidth: .infinity)
                        filePreview.frame(minWidth: 280, idealWidth: 360, maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 10) {
                        memberTable.frame(minHeight: 100)
                        if showsPreview {
                            filePreview.frame(height: min(240, max(130, geometry.size.height * 0.48)))
                        }
                    }
                }
            }.frame(minHeight: 260)
            if model.contents == nil {
                if model.needsPassword { passwordControls }
                if let error = model.error {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                        Spacer()
                        Button(L("android.retry", "重试")) { model.load() }.disabled(model.isLoading)
                    }
                }
            }
            DisclosureGroup(L("archive.preview.details", "归档详情与预览说明"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 5) {
                    if let member = selected?.member {
                        Text(L("archive.preview.method", "压缩方式") + ": " + member.method + " · " + L("archive.preview.packed", "压缩后") + ": " + bytes(member.packedSize))
                        if member.encrypted { Label(L("archive.preview.encrypted", "已加密"), systemImage: "lock") }
                    }
                    Text(L("archive.preview.hint", "列表不解出普通压缩包；查看文件仅临时解出所选项（最大 64 MiB），不打开外部应用，关闭后删除。压缩 TAR 预览需临时展开中间归档（最大 512 MiB）。"))
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }.font(.caption)
            Divider().opacity(0.6)
            HStack {
                Button(L("archive.preview.file", "查看所选文件")) { showSelected() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(selected == nil || selected?.directory == true)
                Text(L("archive.preview.gesture", "双击文件夹进入 · 空格预览文件"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Menu(L("archive.preview.extractAll", "解压全部")) {
                    Button(L("action.extractHere", "解压到当前文件夹")) { extract(to: request.destination) }
                    Button(L("action.extractFolder", "解压到独立文件夹")) { extract(to: request.destination, createFolder: true) }
                    Button(L("action.extractTo", "解压到…")) { choosingDestination = true }
                }.fixedSize().disabled(model.contents == nil || !browser.canMutateFiles || model.isLoading || model.isPreparing)
            }
        }
        .padding(20).background(InterfaceStyle.canvas)
        .frame(minWidth: 720, idealWidth: 1080, maxWidth: 1200, minHeight: 540, idealHeight: 720, maxHeight: 900)
        .onAppear { model.load() }
        .onDisappear { model.close(); password = "" }
        .onChange(of: query) { _ in selection = nil }
        .sheet(isPresented: $choosingDestination) {
            FolderPickerSheet(initialDirectory: request.destination, title: L("archive.chooseDestination", "选择解压文件的保存位置")) { directory in
                extract(to: directory)
                return nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            PageIcon(symbol: "archivebox", compact: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.archive.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle).help(request.archive.path)
                if let contents = model.contents {
                    Text(L("archive.preview.summary", "%d 个项目 · 已知原始大小 %@", contents.entries.count, bytes(contents.totalSize)))
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text(L("archive.preview.title", "预览压缩包")).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("archive.preview.filter", "筛选包内文件名或路径"), text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("archive.preview.filter")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help(L("search.clearFilter", "清除筛选"))
                }
            }.padding(8).modifier(InsetSurface()).frame(width: 240)
            Button(L("button.close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            Button { navigate(to: directory.split(separator: "/").dropLast().joined(separator: "/")) } label: { Image(systemName: "arrow.up") }
                .disabled(directory.isEmpty || isFiltering).help(L("archive.preview.up", "上一级"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button(L("archive.preview.root", "压缩包")) { navigate(to: "") }
                    if isFiltering {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        Text(L("archive.preview.allMatches", "搜索整个压缩包"))
                    } else {
                        let parts = directory.split(separator: "/").map(String.init)
                        ForEach(parts.indices, id: \.self) { index in
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            Button(parts[index]) { navigate(to: parts.prefix(index + 1).joined(separator: "/")) }
                        }
                    }
                }.font(.callout).buttonStyle(.link).fixedSize()
            }
            Text(L("archive.preview.visibleCount", "%d 项", entries.count)).font(.caption).foregroundStyle(.secondary)
            Button { showsPreview.toggle() } label: { Image(systemName: "sidebar.trailing") }
                .help(L("archive.preview.toggle", "显示或隐藏文件预览"))
                .accessibilityIdentifier("archive.preview.toggle")
        }
    }

    private var memberTable: some View {
        Table(entries, selection: $selection) {
            TableColumn(L("column.name", "名称")) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.directory ? "folder.fill" : row.member?.isLink == true ? "link" : "doc")
                        .foregroundStyle(row.directory ? Color.accentColor : .secondary)
                    Text(isFiltering ? row.path : row.name).lineLimit(1).truncationMode(.middle)
                    if row.member?.encrypted == true { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                }.help(row.path)
            }.width(min: 160, ideal: 300)
            TableColumn(L("column.size", "大小")) { Text($0.directory ? "—" : bytes($0.member?.size)).monospacedDigit().foregroundStyle(.secondary) }.width(80)
            TableColumn(L("column.type", "类型")) { row in
                Text(row.directory ? L("type.folder", "文件夹") : row.member?.isLink == true ? L("archive.preview.link", "链接") : (row.name as NSString).pathExtension.uppercased())
                    .lineLimit(1).foregroundStyle(.secondary)
            }.width(80)
        }
        .modifier(InsetSurface()).accessibilityIdentifier("archive.preview.entries")
        .background(TableDoubleClickInstaller { table in
            TableDiagnostics.installDoubleClick(on: table) { row in
                let visible = entries
                guard visible.indices.contains(row) else { return }
                let entry = visible[row]
                selection = entry.id
                if entry.directory { navigate(to: entry.path) }
                else { show(entry) }
            }
        }.frame(width: 0, height: 0))
        .overlay {
            if entries.isEmpty {
                InterfaceStateView(symbol: isFiltering ? "magnifyingglass" : "archivebox",
                    title: model.isLoading ? L("archive.preview.loading", "正在读取压缩包目录…") : model.needsPassword ? L("archive.error.passwordRequired", "此压缩包需要密码。") : L("archive.preview.empty", "没有可显示的项目"),
                    detail: isFiltering ? L("archive.preview.noMatches", "试试其他名称，或清除搜索返回目录。") : "", loading: model.isLoading)
                    .allowsHitTesting(false)
            }
        }
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(previewMember?.path.split(separator: "/").last.map(String.init) ?? L("archive.preview.file", "查看所选文件"))
                    .font(.headline).lineLimit(1).truncationMode(.middle).help(previewMember?.path ?? "")
                Spacer(minLength: 4)
                Button { showsPreview = false; model.clearPreview(); previewMember = nil; password = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(L("archive.preview.closeFile", "关闭文件预览"))
            }
            Divider().opacity(0.5)
            if let preview = model.preview {
                ArchiveQuickLookView(url: preview.url).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isPreparing {
                InterfaceStateView(symbol: "doc", title: L("archive.preview.preparing", "正在准备预览…"), detail: "", loading: true)
                Button(L("button.cancel", "取消")) { model.clearPreview() }
            } else if model.needsPassword {
                Text(L("archive.error.passwordRequired", "此压缩包需要密码。")).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                passwordControls
                Spacer(minLength: 0)
            } else if let error = model.error {
                InterfaceStateView(symbol: "exclamationmark.triangle", title: L("archive.preview.failed", "暂时无法预览"), detail: error)
                Button(L("android.retry", "重试")) { if let member = previewMember { model.show(member) } }
            } else {
                InterfaceStateView(symbol: "doc.text.magnifyingglass", title: previewMember?.canPreview == false ? L("archive.preview.unavailable", "此项目无法直接预览") : L("archive.preview.choose", "选择文件后按空格预览"),
                    detail: previewMember?.canPreview == false ? L("archive.preview.extractHint", "不预览链接。大于 64 MiB 的文件可先解压，再打开查看。") : L("archive.preview.explicitHint", "双击文件也可预览；单击选择不会解压文件。"))
                if previewMember?.canPreview == false && previewMember?.isLink == false {
                    Button(L("archive.preview.extractAll", "解压全部")) { choosingDestination = true }.disabled(!browser.canMutateFiles)
                }
            }
        }.padding(12)
            .background(InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(InterfaceStyle.border.opacity(0.6)))
    }

    private var passwordControls: some View {
        HStack {
            SecureField(L("archive.password.placeholder", "密码（仅用于本次解压）"), text: $password).textFieldStyle(.roundedBorder).onSubmit { unlock() }
            Button(L("archive.preview.unlock", "解锁预览")) { unlock() }.disabled(password.isEmpty || model.isPreparing || model.isLoading)
        }
    }

    private func navigate(to path: String) { directory = path; query = ""; selection = nil }
    private func unlock() {
        guard !password.isEmpty else { return }
        let secret = password
        password = ""
        if model.contents == nil { model.load(password: secret) }
        else if let member = previewMember { model.show(member, password: secret) }
    }
    private func showSelected() { if let selected { show(selected) } }
    private func show(_ entry: ArchiveBrowserEntry) {
        guard !entry.directory, let member = entry.member else { return }
        if previewMember?.id == member.id && (model.preview != nil || model.isPreparing) { showsPreview = true; return }
        model.clearPreview()
        password = ""
        previewMember = member
        showsPreview = true
        if member.canPreview { model.show(member) }
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
