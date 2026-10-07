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
        let base = fm.temporaryDirectory.appendingPathComponent("winfile-demo-\(UUID().uuidString)")
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
    enum Mode: String { case details, icons, home, thisPC }

    static func render(path: String, mode: Mode = .details) {
        let fm = FileManager.default
        let demo = makeDemoFolder()
        defer { try? fm.removeItem(at: demo) }

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
        case .home, .thisPC:
            engine.restrictScopeForTesting([demo])
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
}
