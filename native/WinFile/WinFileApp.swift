// 应用入口：原生 SwiftUI 生命周期、菜单栏、设置与关于面板
import AppKit
import SwiftUI

@main
struct WinFileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = FSEngine()
    @ObservedObject private var localization = Localization.shared
    @AppStorage("StartFolderPath") private var startFolderPath: String = ""

    var body: some Scene {
        WindowGroup {
            MainView(engine: engine)
                .environment(\.locale, localization.locale)
                .frame(minWidth: 860, minHeight: 520)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { WinFileCommands(engine: engine) }

        Settings {
            SettingsView(engine: engine)
                .environment(\.locale, localization.locale)
        }
    }

    private var startDirectory: URL? {
        startFolderPath.isEmpty ? nil : URL(fileURLWithPath: startFolderPath)
    }
}

/// 当前窗口的 UI 接口（引用类型，供自动化测试调用；不参与界面逻辑）
@MainActor
final class WindowBridge {
    static let shared = WindowBridge()
    weak var tabManager: TabManager?
    var navigate: ((SidebarSelection) -> Void)?
    var navigationCount = 0
    /// 当前地址栏应显示的位置标识（由界面层计算并登记，用于验证）
    var currentAddressIdentity: String = ""
    /// 各关键视图的求值次数（用于定位"哪一层没有重绘"）
    var pathBarEvaluations = 0

    // MARK: 页签高亮验证
    private var chipActiveThisPass: [Bool] = []
    private var chipPassInProgress = true
    /// 最近一次完整界面重绘中，各页签的高亮状态
    private(set) var lastChipActiveStates: [Bool] = []
    /// 含高亮的重绘次数（用于判断切换后是否发生了重绘）
    private(set) var chipRenderPasses = 0

    /// 内容区当前渲染的视图类型（供自动化验证）
    private(set) var lastContentKind = "-"
    private(set) var contentRenderCount = 0

    /// 各页签在窗口中的位置（供自动化精确点击）
    private(set) var chipFrames: [UUID: CGRect] = [:]
    private(set) var chipOrder: [(id: UUID, title: String)] = []

    func registerChip(id: UUID, title: String) {
        if let index = chipOrder.firstIndex(where: { $0.id == id }) {
            chipOrder[index] = (id, title)
        } else {
            chipOrder.append((id, title))
        }
    }

    func setChipFrame(id: UUID, frame: CGRect) {
        chipFrames[id] = frame
    }

    /// 按顺序返回页签的位置
    func orderedChipFrames() -> [(title: String, frame: CGRect)] {
        chipOrder.compactMap { entry in
            guard let frame = chipFrames[entry.id] else { return nil }
            return (entry.title, frame)
        }
    }

    func recordContentKind(_ kind: String) {
        if lastContentKind != kind {
            TabDiagnostics.shared.record("content", detail: "渲染=\(kind)")
        }
        lastContentKind = kind
        contentRenderCount += 1
    }

    func beginChipPass() {
        chipActiveThisPass = []
        chipPassInProgress = true
    }

    func recordChipActive(_ active: Bool) {
        chipActiveThisPass.append(active)
    }

    /// 一次运行循环后收尾：保存这一轮的高亮状态
    func finishChipPass() {
        guard chipPassInProgress else { return }
        chipPassInProgress = false
        if !chipActiveThisPass.isEmpty {
            lastChipActiveStates = chipActiveThisPass
            chipRenderPasses += 1
        }
    }
    var modelObjectID: String = ""
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 标签页保护定时器（补齐后来创建的窗口）
    private var tabbingGuardTimer: Timer?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { WindowBridge.shared.tabManager?.persistNow() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 关闭 macOS 自带的窗口标签页。
        //
        // 原因：本应用已有一套完整的页签实现（TabManager + 内容区页签栏），
        // 系统的标签页是**另一份独立的窗口实例**，两者数据不互通。
        // 若同时存在，标题栏会出现 ⊕ 按钮，点它新建的是"另一个 WinFile 窗口"，
        // 结果两套页签栏堆叠、状态归属混乱，快捷键也会与应用的 ⌘T 冲突。
        //
        // 必须在窗口创建前设置，因此放在 willFinishLaunching（而非 didFinish）。
        NSWindow.allowsAutomaticWindowTabbing = false
        // 应用级设置可能被 SwiftUI 在创建窗口时覆盖，因此再加一道窗口级保险
        installTabbingGuard()
    }

    /// 逐个窗口禁止标签页。
    ///
    /// 仅靠 `NSWindow.allowsAutomaticWindowTabbing = false` 在 SwiftUI 下不总是生效 ——
    /// WindowGroup 创建窗口时会重新配置标题栏，⊕ 按钮可能仍然出现。
    /// 这里对每个窗口显式设置 `tabbingMode = .disallowed`，
    /// 并在有新窗口时补设（含稍后打开的窗口）。
    private func installTabbingGuard() {
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
            window.tabbingIdentifier = ""
        }
        // SwiftUI 可能稍后才创建/恢复窗口，这里持续补设（幂等，开销可忽略）
        tabbingGuardTimer?.invalidate()
        tabbingGuardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            for window in NSApp.windows where window.tabbingMode != .disallowed {
                window.tabbingMode = .disallowed
                window.tabbingIdentifier = ""
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 每次启动重置页签交互日志（便于"你操作、我读日志"）
        try? FileManager.default.removeItem(at: TabDiagnostics.liveURL)
        TabDiagnostics.shared.record("app.launch", detail: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        // 界面快照：必须在应用启动完成后执行，否则 SF Symbols 无法解析
        if let index = CommandLine.arguments.firstIndex(of: "--render-snapshot") {
            let target = index + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[index + 1]
                : "/tmp/winfile-snapshot.png"
            var mode = SnapshotRenderer.Mode.details
            if let modeIndex = CommandLine.arguments.firstIndex(of: "--snapshot-mode"),
               modeIndex + 1 < CommandLine.arguments.count,
               let parsed = SnapshotRenderer.Mode(rawValue: CommandLine.arguments[modeIndex + 1]) {
                mode = parsed
            }
            SnapshotRenderer.render(path: target, mode: mode)
            exit(0)
        }
        // 自测模式：不启动界面，直接跑逻辑测试（用于 CI / 回归验证）
        if CommandLine.arguments.contains("--run-tests") {
            NativeTestSuite.run()
            let failures = MainActor.assumeIsolated { TestReporter.shared.failures.count }
            exit(failures == 0 ? 0 : 1)
        }
        // 视图层级转储：用于验证 Table 在真实运行时的行/背景结构
        if let index = CommandLine.arguments.firstIndex(of: "--dump-view-tree"),
           index + 1 < CommandLine.arguments.count {
            let target = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                ViewTreeDumper.dump(to: target)
                exit(0)
            }
        }
        // 页签切换冒烟测试（真实运行环境）
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-tabs"),
           index + 1 < CommandLine.arguments.count {
            let target = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let ok = await TabSmokeTest.run(to: target)
                exit(ok ? 0 : 1)
            }
        }
        // 空白右键判定诊断（在真实界面上核对判定规则）
        if let index = CommandLine.arguments.firstIndex(of: "--probe-context-menu"),
           index + 1 < CommandLine.arguments.count {
            let target = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                ViewTreeDumper.probeContextMenu(to: target)
                exit(0)
            }
        }
        // 沙盒行为探测：验证沙盒是否真正生效、授权书签是否可用

        NSApp.setActivationPolicy(.regular)
        AppUpdater.shared.start()
    }
}

// MARK: - 菜单栏命令（中文，符合 macOS 习惯）

struct WinFileCommands: Commands {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var engine: FSEngine
    @ObservedObject private var updater = AppUpdater.shared
    @FocusedValue(\.browserModel) private var model
    @FocusedValue(\.tabCount) private var tabCount
    @FocusedValue(\.canRestoreTab) private var canRestoreTab

    @ObservedObject private var operationHistory = FileOperationHistory.shared
    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }
    private func clipboardAction(_ selector: String, action: () -> Void) {
        if editingText { NSApp.sendAction(Selector(selector), to: nil, from: nil) }
        else { action() }
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("update.check", "检查更新…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .pasteboard) {
            Button(L("action.cut", "剪切")) { clipboardAction("cut:") { model?.cutSelectionToClipboard() } }
                .keyboardShortcut("x", modifiers: .command)
            Button(L("action.copy", "复制")) { clipboardAction("copy:") { model?.copySelectionToClipboard() } }
                .keyboardShortcut("c", modifiers: .command)
            Button(L("action.paste", "粘贴")) { clipboardAction("paste:") { model?.paste() } }
                .keyboardShortcut("v", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(operationHistory.undoTitle) {
                if editingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                else { operationHistory.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!editingText && !operationHistory.canUndo)
            Button(L("operation.redoText", "重做文本编辑")) {
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editingText)
        }
        // 文件
        CommandGroup(replacing: .newItem) {
            // 页签：与 Windows 资源管理器一致
            Button(L("tab.new", "新标签页")) {
                NotificationCenter.default.post(name: .winFileNewTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button(L("tab.close", "关闭标签页")) {
                if model == nil { NSApp.keyWindow?.performClose(nil) }
                else { NotificationCenter.default.post(name: .winFileCloseTab, object: nil) }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button(L("tab.restore", "恢复关闭的标签页")) { model?.tabManager?.restoreClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(canRestoreTab != true)

            Divider()

            Button(WLocalizedString("menu.newFolder", comment: "新建文件夹")) {
                model?.createFolder(named: WLocalizedString("default.newFolderName", comment: "新建文件夹"))
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model?.currentDirectory == nil)

            Button(WLocalizedString("menu.newTab", comment: "在新窗口中打开")) {
                if let url = model?.currentDirectory {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(model?.currentDirectory == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button(WLocalizedString("menu.copyPath", comment: "复制路径")) {
                model?.copyPathToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button(WLocalizedString("menu.copyName", comment: "复制文件名")) {
                model?.copyNameToClipboard()
            }
            .disabled(model?.selectedIDs.isEmpty ?? true)

            Divider()
            Button(WLocalizedString("menu.duplicate", comment: "制作副本")) {
                model?.duplicateSelection()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model?.selectedIDs.isEmpty ?? true)

            Button(WLocalizedString("menu.rename", comment: "重命名")) {
                NotificationCenter.default.post(name: .winFileBeginRename, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled((model?.selectedCount ?? 0) != 1)
        }

        // 显示
        CommandGroup(after: .toolbar) {
            Button(WLocalizedString("menu.toggleHidden", comment: "显示隐藏文件")) {
                model?.toggleHiddenFiles()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Picker(WLocalizedString("menu.layout", comment: "视图方式"), selection: Binding(
                get: { model?.layout ?? .details },
                set: { model?.setLayout($0) }
            )) {
                Text(WLocalizedString("layout.details", comment: "详细信息")).tag(ViewLayout.details)
                Text(WLocalizedString("layout.icons", comment: "大图标")).tag(ViewLayout.icons)
            }
        }

        // 前往
        CommandMenu(WLocalizedString("menu.go", comment: "前往")) {
            Button(WLocalizedString("menu.back", comment: "后退")) { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))
            Button(WLocalizedString("menu.forward", comment: "前进")) { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.canGoForward ?? false))
            Button(WLocalizedString("menu.up", comment: "上一级")) { model?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(model?.canGoUp ?? false))
            Divider()
            Button(L("view.home", "主页")) { model?.navigate(to: .home) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button(L("view.thisPC", "此电脑")) { model?.navigate(to: .thisPC) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Divider()
            Button(WLocalizedString("menu.home", comment: "个人文件夹")) {
                model?.selectFolder(FileManager.default.homeDirectoryForCurrentUser)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(WLocalizedString("menu.applications", comment: "应用程序")) {
                model?.navigate(to: .applications)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button(WLocalizedString("menu.chooseFolder", comment: "打开文件夹…")) {
                NotificationCenter.default.post(name: .winFileOpenFolder, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // 帮助
        CommandGroup(replacing: .help) {
            Button(WLocalizedString("menu.help", comment: "WinFile 帮助")) {
                NotificationCenter.default.post(name: .winFileShowHelp, object: nil)
            }
            Divider()
            Button(L("menu.openDiagnostics", "打开诊断日志")) {
                NSWorkspace.shared.open(TabDiagnostics.liveURL)
            }
            Button(L("menu.revealDiagnostics", "在访达中显示日志")) {
                NSWorkspace.shared.activateFileViewerSelecting([TabDiagnostics.liveURL])
            }
        }
    }
}

extension Notification.Name {
    static let winFileBeginRename = Notification.Name("WinFileBeginRename")
    static let winFileOpenFolder = Notification.Name("WinFileOpenFolder")
    static let winFileShowHelp = Notification.Name("WinFileShowHelp")
    static let winFileGetInfo = Notification.Name("WinFileGetInfo")
    static let winFileNewTab = Notification.Name("WinFileNewTab")
    static let winFileCloseTab = Notification.Name("WinFileCloseTab")
}

// 让命令能拿到当前窗口的浏览状态
struct BrowserModelKey: FocusedValueKey {
    typealias Value = BrowserModel
}

struct TabCountKey: FocusedValueKey {
    typealias Value = Int
}

struct CanRestoreTabKey: FocusedValueKey { typealias Value = Bool }

extension FocusedValues {
    var canRestoreTab: Bool? {
        get { self[CanRestoreTabKey.self] }
        set { self[CanRestoreTabKey.self] = newValue }
    }
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
    }

    /// 当前窗口的页签数量（菜单据此决定「关闭标签页」是否可用）
    var tabCount: Int? {
        get { self[TabCountKey.self] }
        set { self[TabCountKey.self] = newValue }
    }
}
