// 详细信息窗格：预览、属性、文件夹统计
import SwiftUI

struct InspectorView: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel
    @State private var folderSize: String?
    @State private var computingSize = false

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
        if items.count > 1 { return String(format: NSLocalizedString("inspector.multiSelect", comment: "已选择项目"), items.count) }
        return NSLocalizedString("inspector.currentFolder", comment: "当前文件夹")
    }

    @ViewBuilder
    private func single(_ item: FileItem) -> some View {
        VStack(spacing: 8) {
            FileIconView(engine: engine, item: item, size: 64)
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
                Text(NSLocalizedString("inspector.folderSize", comment: "文件夹大小"))
                    .font(.caption).foregroundStyle(.secondary)
                if computingSize {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(NSLocalizedString("inspector.computing", comment: "正在统计…")).font(.caption)
                    }
                } else {
                    Text(folderSize ?? "—").font(.callout)
                }
            }
            .onAppear { computeSize(item) }
            .onChange(of: item.id) { _ in computeSize(item) }
        }

        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Button(NSLocalizedString("action.open", comment: "打开")) { model.activate(item) }
            Button(NSLocalizedString("action.reveal", comment: "在访达中显示")) { engine.revealInFinder([item]) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func multiple(_ selected: [FileItem]) -> some View {
        let bytes = selected.compactMap(\.size).reduce(Int64(0), +)
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: NSLocalizedString("inspector.count", comment: "项目数"), selected.count))
            Text(String(format: NSLocalizedString("inspector.totalSize", comment: "总大小"),
                        FileItem.formatSize(bytes)))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        Divider()
        Button(NSLocalizedString("action.reveal", comment: "在访达中显示")) { engine.revealInFinder(selected) }
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
                Text(String(format: NSLocalizedString("inspector.items", comment: "项目数"), model.items.count))
                let containers = model.items.filter(\.isContainer).count
                Text(String(format: NSLocalizedString("inspector.folders", comment: "文件夹数"), containers))
                if let info = model.volumeInfo(for: dir) {
                    Divider()
                    Text(String(format: NSLocalizedString("inspector.volumeFree", comment: "可用空间"), info.free))
                    Text(String(format: NSLocalizedString("inspector.volumeTotal", comment: "总容量"), info.total))
                }
            }
            .font(.callout)
        } else {
            Text(NSLocalizedString("inspector.noSelection", comment: "未选择任何项目"))
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func attributeRows(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(NSLocalizedString("attr.kind", comment: "种类"), item.isBundle
                ? NSLocalizedString("type.applicationBundle", comment: "应用程序")
                : (item.isDirectory ? NSLocalizedString("type.folder", comment: "文件夹") : item.typeDescription))
            if let size = item.size {
                row(NSLocalizedString("attr.size", comment: "大小"),
                    FileItem.formatSize(size))
            }
            if let modified = item.modified {
                row(NSLocalizedString("attr.modified", comment: "修改时间"), Self.dateFormatter.string(from: modified))
            }
            if let created = item.created {
                row(NSLocalizedString("attr.created", comment: "创建时间"), Self.dateFormatter.string(from: created))
            }
            row(NSLocalizedString("attr.where", comment: "位置"),
                FileSystemService.abbreviate(item.url.deletingLastPathComponent()))
            if item.isBundle, let bundleID = Bundle(url: item.url)?.bundleIdentifier {
                row(NSLocalizedString("attr.bundleID", comment: "标识符"), bundleID)
            }
        }
        .font(.caption)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
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

    private func computeSize(_ item: FileItem) {
        computingSize = true
        folderSize = nil
        let url = item.url
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                FileSystemService.directorySize(url)
            }.value
            let unitFiles = NSLocalizedString("unit.files", comment: "个文件")
            let unitFolders = NSLocalizedString("unit.folders", comment: "个文件夹")
            folderSize = "\(FileItem.formatSize(result.bytes)) · \(result.files) \(unitFiles) · \(result.folders) \(unitFolders)"
            computingSize = false
        }
    }
}
