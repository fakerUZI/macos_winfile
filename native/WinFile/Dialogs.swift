// 对话框：重命名、新建、打开方式（原生应用列表）、帮助
import AppKit
import SwiftUI

// MARK: - 重命名

struct RenameSheet: View {
    let item: FileItem
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(item: FileItem, onCommit: @escaping (String) -> Void) {
        self.item = item
        self.onCommit = onCommit
        _name = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("dialog.rename.title", comment: "重命名")).font(.headline)
            TextField(NSLocalizedString("dialog.name", comment: "名称"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 360)
            Text(NSLocalizedString("dialog.rename.hint", comment: "扩展名不会被自动修改"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(NSLocalizedString("button.cancel", comment: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("button.ok", comment: "好"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

// MARK: - 通用文本输入

struct TextInputSheet: View {
    let titleKey: String
    let defaultText: String
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(titleKey: String, defaultText: String, onCommit: @escaping (String) -> Void) {
        self.titleKey = titleKey
        self.defaultText = defaultText
        self.onCommit = onCommit
        _text = State(initialValue: defaultText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString(titleKey, comment: "对话框标题")).font(.headline)
            TextField(NSLocalizedString("dialog.name", comment: "名称"), text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .frame(width: 340)
            HStack {
                Spacer()
                Button(NSLocalizedString("button.cancel", comment: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("button.create", comment: "创建"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

// MARK: - 打开方式（原生应用选择列表，取代手填输入）

struct OpenWithSheet: View {
    @ObservedObject var engine: FSEngine
    let item: FileItem
    let onPick: (URL) -> Void
    /// 设为 WinFile 内的默认打开方式（不影响 macOS 的关联设置）
    var onSetDefault: ((URL) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: URL?

    private var candidates: [URL] { engine.applications(for: item) }
    private var defaultApp: URL? { NSWorkspace.shared.urlForApplication(toOpen: item.url) }

    private var filtered: [URL] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter {
            displayName(for: $0).lowercased().contains(needle)
                || (Bundle(url: $0)?.bundleIdentifier ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FileIconView(engine: engine, item: item, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: NSLocalizedString("dialog.openWith.title", comment: "打开方式"), item.name))
                        .font(.headline)
                    if let defaultApp {
                        Text(String(format: NSLocalizedString("dialog.openWith.default", comment: "系统默认"), displayName(for: defaultApp)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("dialog.openWith.search", comment: "搜索应用"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.path) { app in
                        appRow(app)
                    }
                    if filtered.isEmpty {
                        Text(NSLocalizedString("dialog.openWith.empty", comment: "没有匹配的应用"))
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                Button(NSLocalizedString("button.cancel", comment: "取消")) { dismiss() }
                Button(L("assoc.setDefault", "设为默认（仅本应用）")) {
                    if let selected {
                        onSetDefault?(selected)
                        dismiss()
                    }
                }
                .disabled(selected == nil)
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("dialog.openWith.confirm", comment: "用选中的应用打开")) {
                    if let selected { onPick(selected) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            selected = defaultApp ?? candidates.first
        }
    }

    private func appRow(_ app: URL) -> some View {
        let isDefault = app == defaultApp
        let isSelected = app == selected
        return Button {
            selected = app
        } label: {
            HStack(spacing: 10) {
                AppIconView(url: app, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: app)).fontWeight(isDefault ? .semibold : .regular)
                    if let bundleID = Bundle(url: app)?.bundleIdentifier {
                        Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isDefault {
                    Text(NSLocalizedString("dialog.openWith.badge", comment: "默认"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(app.path)
    }

    private func displayName(for url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - 应用图标

struct AppIconView: View {
    let url: URL
    var size: CGFloat = 20
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url.path) {
            let target = size * 2
            let path = url.path
            image = await Task.detached(priority: .userInitiated) {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: target, height: target)
                return ImageBox(image: icon)
            }.value.image
        }
    }
}

// MARK: - 帮助

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String)] {
        [
            ("⌘C / ⌘V", NSLocalizedString("help.copyPaste", comment: "复制、粘贴文件；复制时会同时写入系统剪贴板")),
            ("⌘⌥C", NSLocalizedString("help.copyPath", comment: "复制所选文件的完整路径")),
            ("Return", NSLocalizedString("help.rename", comment: "重命名所选项目")),
            ("⌘⌫", NSLocalizedString("help.delete", comment: "移到废纸篓")),
            ("⌘⇧N", NSLocalizedString("help.newFolder", comment: "新建文件夹")),
            ("⌘[ / ⌘]", NSLocalizedString("help.backForward", comment: "后退 / 前进")),
            ("⌘↑", NSLocalizedString("help.up", comment: "返回上一级文件夹")),
            ("⌘⇧.", NSLocalizedString("help.hidden", comment: "显示或隐藏隐藏文件")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("help.title", comment: "WinFile 使用提示")).font(.headline)
            Text(NSLocalizedString("help.intro", comment: "帮助说明"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { key, description in
                    GridRow {
                        Text(key).font(.system(.callout, design: .monospaced))
                        Text(description).font(.callout)
                    }
                }
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("button.ok", comment: "好")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
