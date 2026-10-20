// 界面快照：在进程内把真实 SwiftUI 视图渲染成 PNG
// 用途：无需屏幕录制权限即可产出界面截图（开发期视觉验证 / 文档配图）
// 用法：WinFile.app/Contents/MacOS/WinFile --render-snapshot /tmp/out.png
//
// 已知限制：基于 NSTableView 的 SwiftUI Table 在同步 cacheDisplay 路径下不会回填数据，
// 因此分类/搜索这类依赖列表异步刷新的视图不适合用本工具截图（界面本身正常）。
// 逻辑正确性由 native/run_native_tests.sh 的断言覆盖。
import AppKit
import Foundation
import SwiftUI

@MainActor
enum SnapshotRenderer {

    /// 生成一个包含各类文件的示例目录，便于截图中展示完整界面
    private static func makeDemoFolder() -> URL {
        let fm = FileManager.default
        // 目录名用可读名称：截图会显示在标签页与面包屑上
        let base = fm.temporaryDirectory.appendingPathComponent("WinFile 示例文件夹")
        let subfolders = ["项目文档", "设计素材", "归档"]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        for folder in subfolders {
            try? fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let files: [(String, String)] = [
            ("季度报告.docx", "报告"),
            ("数据分析.xlsx", "数据"),
            ("产品介绍.pptx", "演示"),
            ("用户手册.pdf", "手册"),
            ("readme.md", "# 说明\n"),
            ("config.json", "{}"),
            ("main.swift", "print()"),
            ("产品海报.png", "png"),
            ("演示视频.mp4", "mp4"),
            ("背景音乐.mp3", "mp3"),
            ("素材包.zip", "zip"),
            ("字体资源.ttf", "ttf"),
        ]
        for (name, content) in files {
            try? content.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return base
    }

    /// 视图模式：详情 / 大图标 / 主页 / 此电脑
    /// （分类与搜索依赖 Table 异步回填，不适合离屏截图，见文件头说明）
    enum Mode: String { case details, icons, home, thisPC, category, wechat, storage, software }

    @MainActor
    static func render(path: String, mode: Mode = .details) {
        if mode == .storage { renderStoragePreview(path: path); return }
        if mode == .software { renderStoragePreview(path: path, softwareMode: true); return }
        if mode == .wechat { renderWeChatPreview(path: path); return }
        let defaults = UserDefaults.standard
        let originalPreferences = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "WinFile")
        defer {
            if let originalPreferences { defaults.setPersistentDomain(originalPreferences, forName: Bundle.main.bundleIdentifier ?? "WinFile") }
            else { defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "WinFile") }
        }
        let fm = FileManager.default
        let demo = makeDemoFolder()
        defer { try? fm.removeItem(at: demo) }

        // 造出与用户截图相似的内容：16 个 PDF，含重名与长短名
        makePDFSamples(in: demo)
        // 授权示例目录，使界面有真实内容
        let engine = FSEngine()
        engine.restrictScopeForTesting([demo])   // 分类检索范围限定在示例目录
        _ = engine.addFolder(demo)

        let model = BrowserModel(engine: engine, startDirectory: demo)
        model.reload()
        // 给 I/O 一点时间完成（截图是同步流程，这里轮询等待）
        let deadline = Date().addingTimeInterval(6)
        while model.items.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        switch mode {
        case .icons:
            engine.restrictScopeForTesting([demo])
            model.layout = .icons
        case .details:
            engine.restrictScopeForTesting([demo])
            if let first = model.items.first(where: { !$0.isContainer }) {
                model.selectedIDs = [first.id]
            }
        case .home, .thisPC, .wechat, .storage, .software:
            engine.restrictScopeForTesting([demo])
        case .category:
            // 分类视图：用于验证网格是否完整渲染所有条目
            engine.restrictScopeForTesting([demo])
            model.layout = .icons
            model.navigate(to: .category(.pdf))
            let catDeadline = Date().addingTimeInterval(15)
            while model.isLoadingCategory && Date() < catDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        // 刷新分类徽标（与分类视图数量应一致）
        engine.scheduleCategoryCount(force: true)
        let countDeadline = Date().addingTimeInterval(5)
        while engine.countingCategories && Date() < countDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        // 通过真实的 NSWindow + NSHostingView 渲染：
        // ImageRenderer 在无窗口环境下无法解析 SF Symbols，会画出占位符，
        // 而真实窗口会走完整的绘制管线，得到的画面与应用中看到的一致。
        let contentSize = NSSize(width: 1180, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WinFile"
        // 让主界面直接打开示例目录：MainView 从 StartFolderPath 读取起始位置，
        // 不设置的话内容区会停在空目录上（快照只剩界面框架）。
        UserDefaults.standard.set(demo.path, forKey: "StartFolderPath")
        let hosting = NSHostingView(rootView: MainView(engine: engine, skipAutoNavigation: true))
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)

        // 让 SwiftUI 完成一轮布局与绘制（异步图片与 I/O 也需要时间）
        let settle = Date().addingTimeInterval(2.5)
        while Date() < settle {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        // 主页 / 此电脑 需要加载数据后才能如实反映界面
        switch mode {
        case .home:
            model.loadHome()
            let deadline = Date().addingTimeInterval(10)
            while model.isLoadingHome && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        case .thisPC:
            model.loadThisPC()
            let deadline = Date().addingTimeInterval(10)
            while model.isLoadingDrives && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        default:
            break
        }
        let settleAgain = Date().addingTimeInterval(1.2)
        while Date() < settleAgain {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // 基于 NSTableView 的 Table 需要运行循环推进才会回填数据，
        // 因此这里必须让运行循环转一会儿（已关闭自动导航，不会被改写状态）
        let renderSettle = Date().addingTimeInterval(2.0)
        while Date() < renderSettle {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        print("   [诊断] 模式=\(mode.rawValue) 主页=\(model.isHomeView) 此电脑=\(model.isThisPCView) 目录=\(model.currentDirectory?.path ?? "无") items=\(model.items.count) 驱动器=\(model.drives.count) 快速访问=\(model.quickAccess.count) 状态=\(model.statusMessage)")

        guard let contentView = window.contentView,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            print("渲染失败：无法创建位图")
            exit(1)
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败：无法编码 PNG")
            exit(1)
        }
        // 若请求了右键判定诊断，在真实渲染后的窗口上核对判定规则
        if let probeIndex = CommandLine.arguments.firstIndex(of: "--probe-context-menu"),
           probeIndex + 1 < CommandLine.arguments.count {
            ViewTreeDumper.probeContextMenu(to: CommandLine.arguments[probeIndex + 1])
            ViewTreeDumper.dump(to: CommandLine.arguments[probeIndex + 1] + ".tree.txt")
        }

        window.orderOut(nil)

        let url = URL(fileURLWithPath: path)
        do {
            try png.write(to: url)
            print("界面快照已生成：\(url.path)（\(Int(contentSize.width))x\(Int(contentSize.height)) pt @2x，\(png.count) 字节）")
            print("注意：本工具用离屏窗口渲染，基于 NSTableView 的列表在离屏路径下可能回填不出行；")
            print("      界面正确性请以 native/run_native_tests.sh 的断言与真机运行为准。")
        } catch {
            print("写入失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    /// Uses temporary attachment fixtures and never scans the user's real WeChat data.
    private static func renderWeChatPreview(path: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WinFile-WeChat-Preview-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for name in ["File/Project Proposal.pdf", "Image/Holiday.jpg", "Video/Meeting.mp4", "File/Archive.zip"] {
            let url = root.appendingPathComponent(name)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0, count: 2048).write(to: url)
        }
        let result = WeChatCleanupService.scan(roots: [root])
        let store = WeChatCleanupModel(initialResult: result)
        let width = CommandLine.arguments.contains("--compact-preview") ? 640 : 940
        let height = CommandLine.arguments.contains("--short-preview") ? 360 : 640
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WinFile"
        let model = BrowserModel(engine: FSEngine(), startDirectory: nil, cleanupModel: store)
        model.navigate(to: .weChatCleanup)
        let hosting = NSHostingView(rootView: WeChatCleanupView(model: model, dialog: .constant(nil))
            .environment(\.locale, Localization.shared.locale)
            .frame(width: CGFloat(width), height: CGFloat(height)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = hosting
        window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        let settle = Date().addingTimeInterval(3)
        while Date() < settle {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print(error); exit(1) }
        window.orderOut(nil)
        print("WeChat fixture preview: \(path)")
    }

    private static func renderStoragePreview(path: String, softwareMode: Bool = false) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WinFile-Storage-Preview-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        var samples = [("Library/Caches/com.example.Editor/编辑器缓存.bin", 128 * 1024),
                       ("Library/Logs/com.example.Editor/应用日志.log", 16 * 1024),
                       ("Downloads/软件安装包.dmg", 1024 * 1024), ("Documents/演示项目/演示视频.mov", 0),
                       ("WeChat Files/wxid_demo/FileStorage/File/2026-10/演示附件.pdf", 32 * 1024)]
        if softwareMode {
            samples += [("Library/Application Support/Google/Chrome/Default/Cache/浏览器缓存.bin", 256 * 1024),
                        ("Library/Application Support/Code/Cache/代码编辑器缓存.bin", 64 * 1024)]
        }
        for (name, size) in samples {
            let url = root.appendingPathComponent(name)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 0, count: size).write(to: url)
            if size == 0, let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: 512 * 1024 * 1024)
                try? handle.seek(toOffset: 0); try? handle.write(contentsOf: Data(repeating: 0, count: 4096)); try? handle.close()
            }
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: url.path)
        }
        let domain = "WinFile.StoragePreview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = StorageCleanupModel(home: root, defaults: defaults, softwareMode: softwareMode)
        if softwareMode { store.selectSoftware("com.microsoft.vscode") }
        store.accept(StorageCleanupService.scan(store.configuration, running: []))
        let chatRoot = root.appendingPathComponent("WeChat Files")
        let chatStore = WeChatCleanupModel(initialResult: WeChatCleanupService.scan(roots: [chatRoot]),
                                          homeDirectory: root, customRoots: [chatRoot])
        let generalStore = softwareMode ? StorageCleanupModel(home: root, defaults: defaults) : store
        let softwareStore = softwareMode ? store : StorageCleanupModel(home: root, defaults: defaults, softwareMode: true)
        let model = BrowserModel(engine: FSEngine(), startDirectory: nil, cleanupModel: chatStore,
                                 storageCleanupModel: generalStore, softwareCleanupModel: softwareStore)
        model.navigate(to: softwareMode ? .weChatCleanup : .storageCleanup)
        let width: CGFloat = CommandLine.arguments.contains("--compact-preview") ? 760 : 1080
        let height: CGFloat = CommandLine.arguments.contains("--short-preview") ? 480 : 700
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = softwareMode ? "WinFile — 软件清理测试" : "WinFile — 空间清理测试"
        let content = AnyView(CleanupHubView(model: model, dialog: .constant(nil)))
        let hosting = NSHostingView(rootView: content
            .environment(\.locale, Localization.shared.locale))
        hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = hosting; window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
        window.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print(error); exit(1) }
        print("Storage cleanup fixture preview: \(path)")
        if CommandLine.arguments.contains("--interactive-preview") {
            while window.isVisible {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
            }
        }
        window.orderOut(nil)
    }

    /// 在示例目录里造出 16 个 PDF（含重名与长短名，用于复现网格问题）
    private static func makePDFSamples(in root: URL) {
        let fm = FileManager.default
        let names = ["lockScreenLiquidDetection.pdf", "ENERGY STAR.pdf",
                     "reader_complimentary_membership_dialog_image.pdf",
                     "ReferenceCardForMac.pdf", "ReferenceCard.pdf", "Doc3.pdf",
                     "Doc2.pdf", "Doc1.pdf"]
        for (index, name) in names.enumerated() {
            let directory = root.appendingPathComponent(index < 4 ? "子目录A" : "子目录B")
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? "%PDF-1.4 sample".write(to: directory.appendingPathComponent(name),
                                         atomically: true, encoding: .utf8)
        }
    }
}
