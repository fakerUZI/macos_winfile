// 文件列表的双击打开
//
// 为什么不用 SwiftUI 的手势：
//   - `.onTapGesture(count: 2)` 与系统双击竞争，实测抢不到；
//   - `Table` 的 `primaryAction` 在右键/选择状态变化后可能不触发。
// 因此直接在底层 `NSTableView` 上挂 `doubleAction` —— 这是 AppKit 的原生机制，最可靠。
import AppKit
import SwiftUI

/// 把自己所属的 NSTableView 交给回调（用于安装双击处理）
struct TableDoubleClickInstaller: NSViewRepresentable {
    let install: (NSTableView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = InstallerView()
        view.install = install
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? InstallerView)?.install = install
    }


    final class InstallerView: NSView {
        var install: ((NSTableView) -> Void)?
        private weak var installed: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 布局完成后才能找到同区域的表格
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        @MainActor
        private func attach() {
            guard let window else { return }
            // 取"最宽"的表格：文件列表远比侧边栏宽
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView { tables.append(table) }
                for child in view.subviews { collect(child) }
            }
            collect(window.contentView ?? NSView())
            guard let target = tables.max(by: { $0.bounds.width < $1.bounds.width }),
                  target !== installed else { return }
            installed = target
            install?(target)
        }
    }
}

enum TableDiagnostics {

    /// 给表格安装双击处理。
    ///
    /// 用 `doubleAction` 而非事件监听：前者由 AppKit 在识别到双击时调用，
    /// 且调用前第一次点击已完成行选中，因此可用 `selectedRow` 判定目标行。
    @MainActor
    static func installDoubleClick(on table: NSTableView, handler: @escaping (Int) -> Void) {
        let proxy = DoubleClickProxy(handler: handler)
        table.target = proxy
        table.doubleAction = #selector(DoubleClickProxy.handleDoubleClick(_:))
        // 让 proxy 随表格存活
        objc_setAssociatedObject(table, &DoubleClickProxy.key, proxy, .OBJC_ASSOCIATION_RETAIN)
        TabDiagnostics.shared.record("doubleClick.installed",
                                     detail: "表格宽度 \\(Int(table.bounds.width)) 行数 \\(table.numberOfRows)")
    }
}

/// doubleAction 的接收者（NSTableView 用 target/action，必须是 Objective-C 对象）
final class DoubleClickProxy: NSObject {
    static var key: UInt8 = 0
    private let handler: (Int) -> Void

    init(handler: @escaping (Int) -> Void) {
        self.handler = handler
    }

    @objc func handleDoubleClick(_ sender: NSTableView) {
        MainActor.assumeIsolated { perform(sender) }
    }

    @MainActor
    private func perform(_ table: NSTableView) {
        // clickedRow 在双击时有效；退回到 selectedRow
        var row = table.clickedRow
        if row < 0 { row = table.selectedRow }
        TabDiagnostics.shared.record("doubleClick.fired",
                                     detail: "行=\\(row) 行数=\\(table.numberOfRows)")
        handler(row)
    }
}
