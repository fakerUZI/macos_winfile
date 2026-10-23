// 详细信息窗格：预览、属性、文件夹统计
import SwiftUI

struct InspectorView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @State private var folderSize: String?
    @State private var computingSize = false
    @State private var sizeIsComplete = true
    @State private var sizeLimit = 200_000

    private var items: [FileItem] { model.selectedItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if items.count == 1, let item = items.first {
                        single(item)
                    } else if items.count > 1 {
                        multiple(items)
                    } else {
                        currentFolder
                    }
                }
                .padding(14)
            }
        }
        .background(.regularMaterial)
    }

    private var header: String {
        if items.count == 1 { return items[0].name }
        if items.count > 1 { return String(format: WLocalizedString("inspector.multiSelect", comment: "已选择项目"), items.count) }
        return WLocalizedString("inspector.currentFolder", comment: "当前文件夹")
    }

    @ViewBuilder
    private func single(_ item: FileItem) -> some View {
        VStack(spacing: 8) {
            FileIconView(engine: engine, item: item,
                         size: item.supportsThumbnail && !AndroidURL.isAndroid(item.url) ? 144 : 64)
                .padding(.vertical, 8)
            Text(item.name)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(item.typeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)

        Divider()
        attributeRows(item)

        if item.isDirectory && !item.isBundle {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(WLocalizedString("inspector.folderSize", comment: "文件夹大小"))
                    .font(.caption).foregroundStyle(.secondary)
                if computingSize {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(WLocalizedString("inspector.computing", comment: "正在统计…")).font(.caption)
                    }
                } else {
                    Text(folderSize ?? "—").font(.callout)
                    if !sizeIsComplete {
                        Text(L("inspector.partialSize", "部分统计，实际大小至少为以上数值；部分位置未读取或已达到遍历上限。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("scan.continue", "继续加载 / 深入扫描")) { sizeLimit *= 2 }
                    }
                }
            }
            .task(id: "\(item.id)-\(sizeLimit)") { await computeSize(item) }
        }

        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Button(WLocalizedString("action.open", comment: "打开")) { model.activate(item) }
            Button(WLocalizedString("action.reveal", comment: "在访达中显示")) { engine.revealInFinder([item]) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func multiple(_ selected: [FileItem]) -> some View {
        let bytes = selected.compactMap(\.size).reduce(Int64(0), +)
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: WLocalizedString("inspector.count", comment: "项目数"), selected.count))
            Text(String(format: WLocalizedString("inspector.totalSize", comment: "总大小"),
                        FileItem.formatSize(bytes)))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        Divider()
        Button(WLocalizedString("action.reveal", comment: "在访达中显示")) { engine.revealInFinder(selected) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    @ViewBuilder
    private var currentFolder: some View {
        if let dir = model.currentDirectory {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.yellow)
                    Text(dir.lastPathComponent).font(.headline)
                }
                Text(FileSystemService.abbreviate(dir))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Divider()
                Text(String(format: WLocalizedString("inspector.items", comment: "项目数"), model.items.count))
                let containers = model.items.filter(\.isContainer).count
                Text(String(format: WLocalizedString("inspector.folders", comment: "文件夹数"), containers))
                if let info = model.volumeInfo(for: dir) {
                    Divider()
                    Text(String(format: WLocalizedString("inspector.volumeFree", comment: "可用空间"), info.free))
                    Text(String(format: WLocalizedString("inspector.volumeTotal", comment: "总容量"), info.total))
                }
            }
            .font(.callout)
        } else {
            Text(WLocalizedString("inspector.noSelection", comment: "未选择任何项目"))
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func attributeRows(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(WLocalizedString("attr.kind", comment: "种类"), item.isBundle
                ? WLocalizedString("type.applicationBundle", comment: "应用程序")
                : (item.isDirectory ? WLocalizedString("type.folder", comment: "文件夹") : item.typeDescription))
            if let size = item.size {
                row(WLocalizedString("attr.size", comment: "大小"),
                    FileItem.formatSize(size))
            }
            Divider().padding(.vertical, 4)
            if let modified = item.modified {
                row(WLocalizedString("attr.modified", comment: "修改时间"), Self.dateFormatter.string(from: modified))
            }
            if let created = item.created {
                row(WLocalizedString("attr.created", comment: "创建时间"), Self.dateFormatter.string(from: created))
            }
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(WLocalizedString("attr.where", comment: "位置")).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.copyPathToClipboard(includeDirectory: true)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(L("action.copyDir", "复制所在目录"))
                    .accessibilityLabel(L("action.copyDir", "复制所在目录"))
                }
                Text(FileSystemService.abbreviate(item.url.deletingLastPathComponent()))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if item.isBundle, let bundleID = Bundle(url: item.url)?.bundleIdentifier {
                row(WLocalizedString("attr.bundleID", comment: "标识符"), bundleID)
            }
        }
        .font(.caption)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(minWidth: 62, idealWidth: 78, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func computeSize(_ item: FileItem) async {
        computingSize = true
        folderSize = nil
        let url = item.url
        let limit = sizeLimit
        let token = ScanCancellation()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                FileSystemService.directorySize(url, limit: limit, cancelled: { token.isCancelled })
            }.value
        } onCancel: { token.cancel() }
        guard !Task.isCancelled else { return }
        let unitFiles = WLocalizedString("unit.files", comment: "个文件")
        let unitFolders = WLocalizedString("unit.folders", comment: "个文件夹")
        folderSize = "\(FileItem.formatSize(result.bytes)) · \(result.files) \(unitFiles) · \(result.folders) \(unitFolders)"
        sizeIsComplete = result.isComplete
        computingSize = false
    }
}
