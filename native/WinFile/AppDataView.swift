// 「应用数据」页面：列出各应用的数据目录，双击即可用 WinFile 浏览其中的普通文件
//
// 权限说明：读取其它应用的容器需要「完整磁盘访问权限」，
// 只能由用户在系统设置中手动授予。未授权时页面会给出明确指引。
import AppKit
import SwiftUI

struct AppDataView: View {
    @ObservedObject var engine: FSEngine
    @ObservedObject var model: BrowserModel

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 14)]

    @State private var showsHint = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.needsFullDiskAccess && showsHint {
                    permissionHint
                }
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Color.accentColor)
                Text(L("appData.title", "应用数据"))
                    .font(.title3).fontWeight(.semibold)
                if model.isLoadingAppData {
                    ProgressView().controlSize(.small)
                }
            }
            Text(L("appData.subtitle", "选择应用即可浏览它保存的文件（附件、缓存、导出内容等）"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("appData.needAccess.title", "需要「完整磁盘访问权限」才能读取其它应用的数据"),
                  systemImage: "lock.shield")
                .fontWeight(.medium)
            Text(L("appData.needAccess.detail",
                   "macOS 会保护其它应用的数据目录，此权限只能由你手动授予，应用无法自行申请。\n路径：系统设置 → 隐私与安全性 → 完整磁盘访问权限 → 勾选 WinFile，然后重新打开应用。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("appData.openSettings", "打开系统设置")) {
                    openPrivacySettings()
                }
                Button(L("appData.rescan", "重新扫描")) { model.loadAppData() }
                Button(L("appData.hideHint", "不再提示")) { showsHint = false }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor))
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingAppData && model.appDataItems.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("appData.scanning", "正在扫描…")).foregroundStyle(.secondary)
            }
        } else if model.appDataItems.isEmpty {
            Text(L("appData.empty", "没有发现可浏览的应用数据目录。"))
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(model.appDataItems) { item in
                    AppDataCard(engine: engine, item: item,
                                open: { model.selectFolder(item.dataURL) })
                }
            }
        }
    }

    private func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        ]
        for string in urls {
            if let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}

/// 单个应用的数据目录卡片
struct AppDataCard: View {
    @ObservedObject var engine: FSEngine
    let item: AppDataItem
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if item.isContainer {
                            Text(L("appData.badge.container", "容器"))
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        }
                    }
                    Text(FileSystemService.abbreviate(item.dataURL))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.isReadable {
                        Text(L("appData.badge.locked", "无权限访问"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: hovering ? .selectedContentBackgroundColor.withAlphaComponent(0.12)
                                                  : .controlBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("action.open", "打开")) { open() }
            if let appURL = item.appURL {
                Button(L("appData.openApp", "打开应用")) { NSWorkspace.shared.open(appURL) }
            }
            Button(L("action.reveal", "在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.dataURL])
            }
            Divider()
            Button(L("action.copyPath", "复制完整路径")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(item.dataURL.path, forType: .string)
            }
            Button(L("appData.copyBundleID", "复制 Bundle 标识")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(item.bundleID, forType: .string)
            }
        }
        .help(item.dataURL.path)
    }

    @ViewBuilder
    private var icon: some View {
        if let appURL = item.appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color(nsColor: .systemBlue))
                .frame(width: 32, height: 32)
        }
    }
}
