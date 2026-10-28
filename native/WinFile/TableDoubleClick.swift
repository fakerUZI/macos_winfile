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
        guard let installer = view as? InstallerView else { return }
        installer.install = install
        installer.scheduleAttach()
    }


    final class InstallerView: NSView {
        var install: ((NSTableView) -> Void)?
        private weak var installed: NSTableView?
        private var retryCount = 0
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            retryCount = 0
            scheduleAttach()
        }

        override func layout() {
            super.layout()
            scheduleAttach()
        }

        func scheduleAttach() {
            guard window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.scheduled = false
                self?.attach()
            }
        }

        @MainActor
        private func attach() {
            guard let window else { return }
            // SwiftUI may insert the sidebar before the file table has a frame.
            // Match the background marker's actual region rather than picking a
            // table elsewhere in the window, and retry after the next layout.
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView { tables.append(table) }
                for child in view.subviews { collect(child) }
            }
            collect(window.contentView ?? NSView())
            let anchor = convert(NSPoint.zero, to: nil)
            let candidates = tables.filter { table in
                guard let region = table.enclosingScrollView, !region.isHidden else { return false }
                return region.convert(region.bounds, to: nil).insetBy(dx: -1, dy: -1).contains(anchor)
            }
            guard let target = candidates.max(by: { $0.bounds.width < $1.bounds.width }) else {
                if retryCount < 20 {
                    retryCount += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.scheduleAttach() }
                }
                return
            }
            // SwiftUI can replace a table's target/action after installation.
            // Reattach on the next layout instead of trusting the old table identity.
            if target === installed, target.target is DoubleClickProxy,
               target.doubleAction == #selector(DoubleClickProxy.handleDoubleClick(_:)) { return }
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
                                     detail: "表格宽度 \(Int(table.bounds.width)) 行数 \(table.numberOfRows)")
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
                                     detail: "行=\(row) 行数=\(table.numberOfRows)")
        handler(row)
    }
}
