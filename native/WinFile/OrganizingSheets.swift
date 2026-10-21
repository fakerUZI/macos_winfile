import AppKit
import SwiftUI

struct BatchRenameSheet: View {
    @ObservedObject var model: BrowserModel
    let items: [FileItem]
    @Environment(\.dismiss) private var dismiss
    @State private var rules = BatchRenameRules()
    @State private var plan: BatchRenamePlan?
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("rename.batch", "批量重命名")).font(.headline)
            HStack {
                TextField(L("rename.find", "查找文本"), text: $rules.find)
                TextField(L("rename.replace", "替换为"), text: $rules.replacement)
            }
            HStack {
                TextField(L("rename.prefix", "添加前缀"), text: $rules.prefix)
                TextField(L("rename.suffix", "添加后缀（扩展名前）"), text: $rules.suffix)
            }
            Toggle(L("rename.numbered", "添加序号，保留文件扩展名"), isOn: $rules.numbered)
            if rules.numbered {
                HStack {
                    TextField(L("rename.base", "统一名称（留空保留原名）"), text: $rules.baseName)
                    Stepper(L("rename.start", "起始：%d", rules.start), value: $rules.start, in: 0...999999)
                    Stepper(L("rename.digits", "%d 位", rules.digits), value: $rules.digits, in: 1...9)
                }
            }
            Table(plan?.entries ?? []) {
                TableColumn(L("rename.original", "原名称")) { Text($0.source.lastPathComponent).lineLimit(1).help($0.source.path) }
                TableColumn(L("rename.proposed", "新名称")) { Text($0.target.lastPathComponent).lineLimit(1) }
                TableColumn(L("rename.check", "检查")) { Text($0.issue ?? ($0.changes ? "✓" : L("rename.unchanged", "无变化"))).foregroundStyle($0.issue == nil ? Color.secondary : Color.red) }
            }.frame(minHeight: 230)
            if let message { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(L("rename.previewHint", "先检查预览；重名不会覆盖。完成后可用 ⌘Z 撤销。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("button.cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(L("rename.apply", "应用重命名")) { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(busy || plan?.canApply != true || plan?.rules != rules || !model.canMutateFiles)
            }
        }.padding(20).frame(width: 740, height: 520).textFieldStyle(.roundedBorder)
        .disabled(busy).interactiveDismissDisabled(busy)
        .task(id: rules) {
            let captured = rules
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let preview = await Task.detached(priority: .userInitiated) { BatchRenameService.preview(items, rules: captured) }.value
            guard !Task.isCancelled else { return }
            plan = preview
        }
    }
    private func apply() {
        guard let plan, plan.rules == rules, plan.canApply else { return }
        busy = true; message = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { BatchRenameService.apply(plan) }.value
            FileOperationHistory.shared.record(title: L("rename.batch", "批量重命名"), moves: outcome.moves, batchRename: true)
            model.reload()
            NotificationCenter.default.post(name: .winFileFilesChanged, object: nil)
            busy = false
            if outcome.errors.isEmpty { dismiss() } else { message = outcome.errors.joined(separator: "\n"); self.plan = nil }
        }
    }
}

@MainActor
final class DuplicateScanModel: ObservableObject {
    @Published var result: DuplicateScanResult?
    @Published var progress = DuplicateScanProgress()
    @Published var busy = false
    private var token: ScanCancellation?
    private var generation = UUID()
    func cancel() { token?.cancel() }
    func scan(_ root: URL, showHidden: Bool) {
        guard !busy else { return }
        let token = ScanCancellation(); self.token = token
        let id = UUID(); generation = id; busy = true; result = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var last = Date.distantPast
                return DuplicateFileService.scan(root, showHidden: showHidden, token: token) { progress in
                    guard Date().timeIntervalSince(last) > 0.1 else { return }; last = Date()
                    Task { @MainActor [weak self] in if self?.generation == id { self?.progress = progress } }
                }
            }.value
            guard let self, self.generation == id else { return }
            self.generation = UUID(); self.result = result; self.busy = false; self.token = nil
        }
    }
    deinit { token?.cancel() }
}

struct DuplicateFilesSheet: View {
    @ObservedObject var model: BrowserModel
    @StateObject private var scan = DuplicateScanModel()
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    init(model: BrowserModel) {
        self.model = model
        _folder = State(initialValue: model.currentDirectory?.isFileURL == true ? model.currentDirectory : nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("duplicates.title", "查找重复文件")).font(.headline)
            HStack {
                Text(folder?.path ?? L("duplicates.chooseHint", "选择要检查的本机文件夹")).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("settings.choose", "选择…")) { choose() }.disabled(scan.busy)
                if scan.busy { Button(L("button.cancel", "取消")) { scan.cancel() } }
                else { Button(L("duplicates.scan", "开始查找")) { if let folder { scan.scan(folder, showHidden: model.showHidden) } }.disabled(folder == nil) }
            }
            Text(L("duplicates.explain", "按完整文件内容比对；跳过符号链接、应用包内部和同一文件的硬链接。仅列出结果，可先预览再跳转整理。"))
                .font(.caption).foregroundStyle(.secondary)
            if scan.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("duplicates.progress", "已检查 %d 项，已比对 %d / %d 个候选文件", scan.progress.visited, scan.progress.hashed, scan.progress.candidates)).font(.caption)
                }
                Text(scan.progress.currentName).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
            }
            if let result = scan.result {
                Text(L("duplicates.summary", "%d 组重复文件，可整理的逻辑大小 %@", result.groups.count,
                       FileItem.formatSize(result.groups.reduce(0) { $0 + $1.redundantBytes }))).font(.callout)
                if result.cancelled || result.limited || result.unreadable > 0 || result.changed > 0 {
                    Text(L("duplicates.partial", "结果可能不完整：取消 %d，达到扫描上限 %d，无法读取 %d，扫描时发生变化 %d。",
                           result.cancelled ? 1 : 0, result.limited ? 1 : 0, result.unreadable, result.changed)).font(.caption).foregroundStyle(.orange)
                }
                List {
                    ForEach(result.groups) { group in
                        Section(FileItem.formatSize(group.size) + " · " + String(group.files.count)) {
                            ForEach(group.files, id: \.path) { url in
                                HStack {
                                    Text(url.path).lineLimit(2).textSelection(.enabled)
                                    Spacer()
                                    Button(L("action.quickLook", "快速预览")) { QuickLookService.shared.show([url]) }
                                    Button(L("action.openContainingFolder", "打开所在文件夹")) { model.openContainingFolder(of: url); dismiss() }
                                }.font(.caption)
                            }
                        }
                    }
                }
            } else { Spacer(); Text(L("duplicates.ready", "选择范围后开始查找" )).foregroundStyle(.secondary); Spacer() }
            HStack { Spacer(); Button(L("button.close", "关闭")) { scan.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 800, height: 560).onDisappear { scan.cancel() }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { folder = panel.url; scan.result = nil }
    }
}
