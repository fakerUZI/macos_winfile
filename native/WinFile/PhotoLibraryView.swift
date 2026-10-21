// 照片图库页面
//
// 通过 PhotoKit 展示系统相册；不直接读取 Photos Library.photoslibrary。
// 支持：相册切换、缩略图、选择、导出原文件、双击用默认应用打开。
import AppKit
import SwiftUI

struct PhotoLibraryView: View {
    @ObservedObject private var localization = Localization.shared
    @StateObject private var store = PhotoLibraryModel()

    var body: some View {
        Group {
            switch store.access {
            case .checking:
                checkingView
            case .needsPermission:
                permissionView(requestable: true)
            case .denied:
                permissionView(requestable: false)
            case .granted, .limited:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task { await store.activate() }
    }

    // MARK: - 授权

    private var checkingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L("photo.checking", "正在读取照片图库…")).foregroundStyle(.secondary)
        }
    }

    private func permissionView(requestable: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text(requestable
                 ? L("photo.permission.title", "允许 WinFile 访问照片")
                 : L("photo.permission.deniedTitle", "无法访问照片图库"))
                .font(.title3.bold())
            Text(requestable
                 ? L("photo.permission.message", "照片图库由系统统一管理，需要你授权后才能显示相册与照片。WinFile 只读取你选择的项目，不会修改图库。")
                 : L("photo.permission.deniedMessage", "请在「系统设置 → 隐私与安全性 → 照片」中允许 WinFile 访问，然后回到这里重新检查。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                if requestable {
                    Button(L("photo.permission.allow", "允许访问")) {
                        Task { await store.retryAccess() }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("photo.permission.openSettings", "打开系统设置")) {
                        store.openPrivacySettings()
                    }
                    Button(L("photo.permission.recheck", "重新检查")) {
                        Task { await store.reloadAfterSettingsChange() }
                    }
                }
            }
        }
        .padding(40)
    }

    // MARK: - 主内容

    private var content: some View {
        HStack(spacing: 0) {
            albumSidebar
                .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                grid
                Divider()
                statusBar
            }
        }
    }

    private var albumSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("photo.albums", "相册"))
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            List(selection: Binding(
                get: { store.selectedAlbumID },
                set: { value in
                    guard let value else { return }
                    Task { await store.select(albumID: value) }
                }
            )) {
                ForEach(store.albums) { album in
                    Label {
                        HStack(spacing: 6) {
                            Text(album.title)
                            Spacer(minLength: 4)
                            Text("\(album.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: album.symbol)
                            .foregroundStyle(album.kind == .favorites ? Color.pink : Color.accentColor)
                    }
                    .tag(album.id)
                }
            }
            .listStyle(.sidebar)
            .disabled(store.isLoading && store.albums.isEmpty)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(store.selectedAlbum?.title ?? L("photo.albums", "相册"))
                .font(.headline)
            Text(L("photo.count", "%d 项", store.assets.count))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if let progress = store.exportProgress {
                Text(progress).font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L("photo.refresh", "刷新"))
            .disabled(store.isLoading || store.isExporting)

            Button {
                chooseExportFolder()
            } label: {
                Label(L("photo.export.selected", "导出所选…"), systemImage: "square.and.arrow.up")
            }
            .disabled(store.selection.isEmpty || store.isExporting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 128, maximum: 176), spacing: 14)]
    }

    private var grid: some View {
        ScrollView {
            if store.assets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: store.isLoading ? "hourglass" : "photo")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(store.isLoading
                         ? L("photo.loading", "正在加载照片…")
                         : L("photo.empty", "这个相册里没有照片。"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.assets) { item in
                        PhotoTile(
                            item: item,
                            selected: store.selection.contains(item.id),
                            onSelect: { extend in store.toggle(item, extend: extend) },
                            onOpen: { store.open(item) }
                        )
                    }
                }
                .padding(14)
            }
        }
        .overlay(alignment: .top) {
            if let message = store.message {
                Text(message)
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(L("photo.summary", "共 %d 项", store.assets.count))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if !store.selection.isEmpty {
                Text(L("photo.selected", "已选 %d 项", store.selection.count))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button(L("photo.selectAll", "全选")) { store.selectAll() }
                .disabled(store.assets.isEmpty)
            if !store.selection.isEmpty {
                Button(L("photo.selectNone", "取消选择")) { store.clearSelection() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - 动作

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("photo.export.choose", "导出到此处")
        panel.message = L("photo.export.chooseHint", "选择照片的导出位置")
        if panel.runModal() == .OK, let url = panel.url {
            store.exportSelection(to: url)
        }
    }
}

// MARK: - 单个项目

private struct PhotoTile: View {
    let item: PhotoAsset
    let selected: Bool
    let onSelect: (Bool) -> Void
    let onOpen: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                }
                if item.isVideo {
                    Text(durationText)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .frame(height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.black.opacity(0.08),
                            lineWidth: selected ? 3 : 1)
            )
            Text(dateText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture { onSelect(NSEvent.modifierFlags.contains(.command)) }
        .contextMenu {
            Button(L("photo.open", "打开")) { onOpen() }
            Button(L("photo.select", "选择")) { onSelect(false) }
        }
        .task(id: item.id) {
            image = await PhotoThumbnails.shared.image(
                for: item.asset,
                pixelSize: CGSize(width: 300, height: 300)
            )
        }
    }

    private var dateText: String {
        guard let date = item.creationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var durationText: String {
        let total = Int(item.asset.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
