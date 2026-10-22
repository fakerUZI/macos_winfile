// 空白处右键菜单
//
// 背景：SwiftUI 的 `Table` 用 `.contextMenu(forSelectionType:)` 时，右键只有落在「行」上
// 才会弹出菜单；点在行以下的空白区域不会触发（Windows 资源管理器会弹出背景菜单）。
//
// 做法：用 AppKit 的 hitTest 精确判断点击位置属于「行 / 滚动条」还是「空白」，
// 只在空白处接管右键并弹出原生 NSMenu，其余情况完全不拦截，保证行交互与滚动不受影响。
import AppKit
import SwiftUI

/// Marks controls outside the file surface so window-wide event monitors cannot steal their menus.
struct BrowserInteractionBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BoundaryView() }
    func updateNSView(_ view: NSView, context: Context) {}
    final class BoundaryView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 安装到窗口上的空白区右键处理
struct EmptyAreaContextMenu: NSViewRepresentable {

    /// 构建菜单项（在弹出瞬间求值，保证状态最新）
    var buildMenu: () -> NSMenu
    /// 区域标记：安装器所在列表的容器（由调用方通过 onMarker 拿到并保存）
    var marker: NSView?

    /// 调用方拿到本次安装的标记视图，供同一列表的安装器互相识别
    var onMarker: ((NSView) -> Void)?

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.buildMenu = buildMenu
        onMarker?(view)
        return view
    }

    func updateNSView(_ view: InstallerView, context: Context) {
        view.buildMenu = buildMenu
        view.marker = marker
        onMarker?(view)
        view.attachIfNeeded()
    }

    static func dismantleNSView(_ view: InstallerView, coordinator: ()) {
        view.detachMonitors()
    }

    final class InstallerView: NSView {
        /// 当前正在处理的右键事件（供行区域几何判断使用）
        static var currentEvent: NSEvent?

        static func isFinite(_ point: NSPoint) -> Bool {
            point.x.isFinite && point.y.isFinite
        }

        /// 激活/失活合成事件可能没有有效位置；在传给 AppKit 命中测试前验证。
        static func mouseLocation(_ event: NSEvent, in window: NSWindow) -> NSPoint? {
            guard event.window === window, let root = window.contentView else { return nil }
            let point = event.locationInWindow
            guard isFinite(point) else { return nil }
            let contentPoint = root.convert(point, from: nil)
            guard isFinite(contentPoint), root.bounds.contains(contentPoint) else { return nil }
            return point
        }
        /// 便于测试访问判定逻辑（保持带标签的签名）
        static func classify(_ hit: NSView, in scrollView: NSScrollView) -> Bool {
            isOnInteractiveContent(hit, scrollView: scrollView)
        }

        /// 某视图是否为另一视图的后代
        static func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
            var current: NSView? = view
            while let node = current {
                if node === ancestor { return true }
                current = node.superview
            }
            return false
        }

        static func isExcluded(_ point: NSPoint, in root: NSView) -> Bool {
            if root is BrowserInteractionBoundary.BoundaryView, !root.isHidden,
               root.convert(root.bounds, to: nil).contains(point) { return true }
            return root.subviews.contains { isExcluded(point, in: $0) }
        }

        /// 在子树中查找第一个滚动视图
        static func firstScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews {
                if let found = firstScrollView(in: child) { return found }
            }
            return nil
        }

        /// 按坐标查找磁贴：收集所有标记的真实矩形，判断点是否落在其中。
        /// 取面积最小的命中者（最贴近用户点击的那个图标）。
        static func tileMarker(at pointInWindow: NSPoint, in root: NSView) -> FileTileMarkerView? {
            guard isFinite(pointInWindow) else { return nil }
            var candidates: [FileTileMarkerView] = []
            func gather(_ view: NSView) {
                if let marker = view as? FileTileMarkerView, marker.item != nil, !marker.isHidden {
                    candidates.append(marker)
                }
                for child in view.subviews { gather(child) }
            }
            gather(root)
            return candidates
                .filter { marker in
                    guard !marker.isHiddenOrHasHiddenAncestor else { return false }
                    let rect = marker.convert(marker.bounds, to: nil)
                    guard rect.width > 0 && rect.height > 0 && rect.contains(pointInWindow) else { return false }
                    // Overscan tiles exist outside the clip view. Their window rectangles
                    // can overlap the address bar; only visible portions may intercept clicks.
                    var ancestor = marker.superview
                    while let view = ancestor {
                        if view is NSClipView, !view.convert(view.bounds, to: nil).contains(pointInWindow) { return false }
                        ancestor = view.superview
                    }
                    return true
                }
                .min { lhs, rhs in
                    let a = lhs.convert(lhs.bounds, to: nil)
                    let b = rhs.convert(rhs.bounds, to: nil)
                    return a.width * a.height < b.width * b.height
                }
        }

        /// 从命中视图沿父链查找 FileTile 标记（保留供其它场景使用）
        static func findTileMarker(from view: NSView) -> FileTileMarkerView? {
            var current: NSView? = view
            while let node = current {
                if let marker = node as? FileTileMarkerView { return marker }
                current = node.superview
            }
            return nil
        }

        /// 向上查找点击位置所属的滚动视图（表格与图标网格都在滚动容器里）
        static func scrollViewOwning(_ view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let node = current {
                if let scrollView = node as? NSScrollView { return scrollView }
                current = node.superview
            }
            return nil
        }

        var buildMenu: (() -> NSMenu)?
        /// 区域标记与归属滚动视图（由 marker 解析得到）
        weak var marker: NSView?
        weak var ownedScrollView: NSScrollView?
        private weak var installedWindow: NSWindow?
        private var monitor: Any?
        private var clickMonitor: Any?

        var activeMonitorCount: Int { (monitor == nil ? 0 : 1) + (clickMonitor == nil ? 0 : 1) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }

        func detachMonitors() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            monitor = nil
            clickMonitor = nil
            installedWindow = nil
            ownedScrollView = nil
        }

        func attachIfNeeded() {
            guard let window else { detachMonitors(); return }
            guard installedWindow !== window || monitor == nil else { return }
            detachMonitors()
            installedWindow = window
            // 标记解析为归属滚动视图（布局完成后执行一次）
            if ownedScrollView == nil, marker != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window, self.installedWindow === window,
                          let marker = self.marker else { return }
                    self.ownedScrollView = Self.firstScrollView(in: marker)
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
            // 弱引用安装器，避免监听闭包持有窗口；两个监听器随视图同步卸载。
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleLeftMouseDown(event)
            }
        }

        func handleLeftMouseDown(_ event: NSEvent) -> NSEvent? {
            guard event.type == .leftMouseDown, let window,
                  let pointInWindow = Self.mouseLocation(event, in: window),
                  let root = window.contentView else { return event }
            guard !Self.isExcluded(pointInWindow, in: root) else { return event }
            let hit = root.hitTest(root.convert(pointInWindow, from: nil))
            TabDiagnostics.shared.record("leftClick",
                                         detail: "次数=\(event.clickCount) 位置=(\(TabDiagnostics.coordinate(pointInWindow.x)),\(TabDiagnostics.coordinate(pointInWindow.y))) 命中=\(hit.map { String(describing: type(of: $0)) } ?? "无")")
            // 双击时补充表格结构，用于定位"为何未命中行"
            if event.clickCount == 2 {
                // 列出所有磁贴标记的实际位置：用于确认"点击是否落在磁贴上"
                var tileInfo: [String] = []
                func gatherTiles(_ view: NSView) {
                    if let marker = view as? FileTileMarkerView, let item = marker.item {
                        let frame = marker.convert(marker.bounds, to: nil)
                        tileInfo.append("\(item.name)@(\(TabDiagnostics.coordinate(frame.midX)),\(TabDiagnostics.coordinate(frame.midY)))")
                    }
                    for child in view.subviews { gatherTiles(child) }
                }
                gatherTiles(root)
                TabDiagnostics.shared.record("tiles",
                                             detail: tileInfo.isEmpty ? "无磁贴标记" : "\(tileInfo.count) 个：\(tileInfo.prefix(8).joined(separator: ", "))")

                // 记录点击位置所在表格的规模，用于定位"未命中行"的原因
                var tableCount = 0
                var tableInfo: [String] = []
                func gatherTables(_ view: NSView) {
                    if let table = view as? NSTableView {
                        tableCount += 1
                        let tablePoint = table.convert(pointInWindow, from: nil)
                        let row = Self.isFinite(tablePoint) ? table.row(at: tablePoint) : -1
                        tableInfo.append("表\(tableCount):宽\(TabDiagnostics.coordinate(table.bounds.width)) 行\(table.numberOfRows) 点击处行\(row)")
                    }
                    for child in view.subviews { gatherTables(child) }
                }
                gatherTables(root)
                TabDiagnostics.shared.record("tables", detail: tableInfo.isEmpty ? "无表格" : tableInfo.joined(separator: " | "))
                // 图标视图（LazyVGrid）没有 NSTableView，双击在这里处理。
                //
                // 注意：不能用 hitTest 沿父链找标记 —— 标记是零尺寸视图，
                // 不参与命中测试。改为收集所有磁贴的真实矩形，用坐标判定。
                if let marker = Self.tileMarker(at: pointInWindow, in: root),
                   let item = marker.item,
                   let activate = marker.onActivate {
                    TabDiagnostics.shared.record("iconDoubleClick",
                                                 detail: "项目=\(item.name) 目录=\(item.isDirectory)")
                    activate()
                    return nil      // 双击已处理，吞掉事件避免重复触发
                }
                var tables: [NSTableView] = []
                func collect(_ view: NSView) {
                    if let table = view as? NSTableView { tables.append(table) }
                    for child in view.subviews { collect(child) }
                }
                collect(root)
                for (index, table) in tables.enumerated() {
                    let pointInTable = table.convert(pointInWindow, from: nil)
                    let row = Self.isFinite(pointInTable) ? table.row(at: pointInTable) : -1
                    let inWindow = table.convert(table.bounds, to: nil)
                    let installed = table.doubleAction != nil
                    TabDiagnostics.shared.record(
                        "tableProbe",
                        detail: "表格#\(index) 宽=\(TabDiagnostics.coordinate(table.bounds.width)) 高=\(TabDiagnostics.coordinate(table.bounds.height)) 行数=\(table.numberOfRows) 窗口Y=\(TabDiagnostics.coordinate(inWindow.minY))…\(TabDiagnostics.coordinate(inWindow.maxY)) 点击处行=\(row) 已装双击=\(installed)")
                }
            }
            return event
        }

        /// 判断事件是否落在「本视图所属列表的空白处」，是则弹菜单并吞掉事件。
        /// 关键：必须限定在本实例自己的滚动视图内，否则侧边栏等其它滚动区域也会被误判。
        func handle(_ event: NSEvent) -> Bool {
            guard event.type == .rightMouseDown, let window,
                  let pointInWindow = Self.mouseLocation(event, in: window),
                  let buildMenu else { return false }
            guard let root = window.contentView else { return false }
            guard !Self.isExcluded(pointInWindow, in: root) else { return false }

            let point = root.convert(pointInWindow, from: nil)
            guard let hit = root.hitTest(point) else { return false }

            // 找到点击位置所属的滚动视图
            guard let scrollView = Self.scrollViewOwning(hit) else { return false }

            // 归属判断：优先使用显式标记（同一列表的安装器共享容器），
            // 无标记时退回水平位置比对，两者都确保不会误吞侧边栏等区域。
            if let owner = ownedScrollView {
                guard scrollView === owner else { return false }
            } else if let marker {
                guard Self.isDescendant(hit, of: marker) || Self.isDescendant(scrollView, of: marker) else { return false }
            } else {
                guard Self.isAnchor(self, inside: scrollView) else { return false }
            }
            InstallerView.currentEvent = event
            defer { InstallerView.currentEvent = nil }
            let interactive = Self.isOnInteractiveContent(hit, scrollView: scrollView)
            TabDiagnostics.shared.record("rightClick",
                                         detail: "命中=\(String(describing: type(of: hit))) 判定=\(interactive ? "行内(交给系统)" : "空白(弹背景菜单)")")
            guard !interactive else { return false }

            let menu = buildMenu()
            guard menu.items.count > 0 else { return false }
            NSMenu.popUpContextMenu(menu, with: event, for: hit)
            return true
        }

        /// 锚点视图：与本实例同区域（同一列表），用于反查归属的滚动视图
        weak var anchorView: NSView?

        /// 查找与本实例同区域的锚点：SwiftUI 会把 representable 平铺在宿主下，
        /// 这里改为在点击时沿坐标向上反查——即从命中的滚动视图出发，
        /// 判断本实例的坐标是否落在该滚动视图范围内。
        static func isAnchor(_ anchor: NSView, inside scrollView: NSScrollView) -> Bool {
            guard let window = anchor.window, let root = window.contentView else { return false }
            let anchorFrame = anchor.convert(anchor.bounds, to: root)
            let scrollFrame = scrollView.convert(scrollView.bounds, to: root)
            // 锚点（零尺寸，位于列表区）落在滚动视图范围内即视为归属。
            // 用中点判定并留 1pt 容差，避免边缘取整误差导致漏判。
            let point = NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)
            return point.x >= scrollFrame.minX - 1 && point.x <= scrollFrame.maxX + 1
                && point.y >= scrollFrame.minY - 1 && point.y <= scrollFrame.maxY + 1
        }

        /// 点击是否落在「行/单元格/滚动条」等可交互内容上（这些交给系统与 SwiftUI 处理）
        ///
        /// 说明：抽成静态纯函数以便单元测试覆盖，避免事件监听误吞正常交互。
        /// 判定顺序（先精确后兜底）：
        ///   1. 控件类（滚动条、按钮、输入框）→ 交互
        ///   2. 沿父链遇到「行/单元格」→ 交互；但有行号可查时以行号为准
        ///   3. 命中的是表格本体 → 用「行高 × 行数」推算内容高度，超出即空白
        ///   4. 其它情况（如 SwiftUI 的普通容器/文档视图）→ 视为空白
        static func isOnInteractiveContent(_ hit: NSView, scrollView: NSScrollView) -> Bool {
            if hit is NSScroller { return true }
            if hit is NSButton || hit is NSSearchField || hit is NSTextField { return true }

            // 图标视图（LazyVGrid）没有表格行可依据，优先用磁贴矩形判断。
            // 必须放在前面：否则命中 documentView 时会提前返回 false，
            // 磁贴自己的菜单（含重命名/打开方式）就被背景菜单顶掉了。
            if let event = Self.currentEvent {
                let point = event.locationInWindow
                var tiles: [NSView] = []
                func gatherTiles(_ view: NSView) {
                    if view is FileTileMarkerView { tiles.append(view) }
                    for child in view.subviews { gatherTiles(child) }
                }
                gatherTiles(scrollView)
                if !tiles.isEmpty {
                    let onTile = tiles.contains { marker in
                        let rect = marker.convert(marker.bounds, to: nil)
                        return rect.width > 1 && rect.height > 1 && rect.contains(point)
                    }
                    if onTile { return true }
                }
            }

            var current: NSView? = hit
            var rowView: NSTableRowView?
            var cellView: NSTableCellView?
            while let node = current, node !== scrollView {
                if node is NSTableHeaderView { return true }
                if rowView == nil, let row = node as? NSTableRowView { rowView = row }
                if cellView == nil, let cell = node as? NSTableCellView { cellView = cell }
                // 命中表格本体（或其内部滚动视图）时，用行区域几何判断
                if let table = node as? NSTableView, let event = Self.currentEvent {
                    let point = table.convert(event.locationInWindow, from: nil)
                    if table.row(at: point) >= 0 { return true }   // 落在某一行上 → 行内
                    return false                                    // 行以下的空白 → 交给背景菜单
                }
                current = node.superview
            }

            // 命中行/单元格：两个信号任一成立即视为交互内容
            //   ① 表格能给出有效行号（最可靠）
            //   ② 命中点在表格的「行区域」内（几何兜底，兼容行号不可用的情形）
            if let rowView {
                if let table = Self.table(of: rowView) {
                    let index = table.row(for: rowView)
                    if index >= 0 && index < table.numberOfRows { return true }
                    // 行号无效时用位置判断：落在行区域内仍算交互
                    let rectInTable = rowView.convert(rowView.bounds, to: table)
                    if !Self.isBelowRows(table, point: rectInTable.origin) { return true }
                } else {
                    return true
                }
                return false
            }
            if cellView != nil { return true }

            // 命中表格本体：按内容高度判断是否已超出最后一行
            if let table = hit as? NSTableView {
                // 把"整个表格底边的位置"折算成表格自身的 y 坐标：
                // 直接取表格 bounds 高度即可（表格铺满可视区），因此用 hit 视图高度近似内容区高度
                let headerHeight: CGFloat = table.headerView?.bounds.height ?? 0
                let probe = NSPoint(x: 0, y: table.bounds.height - headerHeight)
                return !Self.isBelowRows(table, point: probe)
            }
            if hit === scrollView.documentView { return false }
            return false
        }

        /// 向上查找所属的 NSTableView
        static func table(of view: NSView) -> NSTableView? {
            var current: NSView? = view
            while let node = current {
                if let table = node as? NSTableView { return table }
                current = node.superview
            }
            return nil
        }

        /// 表格中「行区域」的底边位置（表格坐标系）。
        /// 优先使用真实行视图的位置（最可靠），无行视图时退回「行数 × 行高」。
        static func rowAreaBottom(_ table: NSTableView) -> CGFloat? {
            let headerHeight: CGFloat = table.headerView?.bounds.height ?? 0
            var maxBottom: CGFloat = 0
            var foundRowView = false
            func scan(_ view: NSView) {
                if let row = view as? NSTableRowView, row.superview === table {
                    foundRowView = true
                    let rect = row.convert(row.bounds, to: table)
                    maxBottom = max(maxBottom, rect.maxY)
                }
                for child in view.subviews { scan(child) }
            }
            for child in table.subviews { scan(child) }
            if foundRowView { return maxBottom }

            let rows = table.numberOfRows
            guard rows > 0 else { return nil }
            let rowHeight = table.rowHeight > 0 ? table.rowHeight : 24
            return headerHeight + CGFloat(rows) * rowHeight
        }

        /// 表格本体是否已超出最后一行（即行下方的空白区）
        static func isBelowRows(_ table: NSTableView, point: NSPoint? = nil) -> Bool {
            guard let bottom = rowAreaBottom(table) else { return true }
            let y = point?.y ?? 0
            return y > bottom + 1
        }
    }
}
