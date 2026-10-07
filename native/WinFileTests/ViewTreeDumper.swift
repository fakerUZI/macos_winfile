// 运行时视图层级转储（开发期诊断：确认 SwiftUI Table 的真实 AppKit 结构）
import AppKit
import Foundation

enum ViewTreeDumper {

    static func dump(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first,
              let root = window.contentView else {
            print("没有可用窗口")
            return
        }
        var lines: [String] = ["窗口: \(window.title) 尺寸: \(Int(window.frame.width))x\(Int(window.frame.height))", ""]
        describe(root, depth: 0, into: &lines)
        let text = lines.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print(text)
        print("\n已写入: \(path)")
    }

    /// 空白处右键判定诊断：在真实界面上核对"行内 / 行下方空白 / 右侧留白"三类位置的判定结果
    static func probeContextMenu(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first,
              let root = window.contentView else {
            print("没有可用窗口")
            return
        }
        var lines: [String] = ["=== 空白处右键判定诊断 ===", ""]

        // 收集所有滚动视图，找出"最宽的"那个（内容区列表；侧边栏明显更窄）
        var scrollViews: [NSScrollView] = []
        func scan(_ view: NSView) {
            if let scroll = view as? NSScrollView { scrollViews.append(scroll) }
            for child in view.subviews { scan(child) }
        }
        scan(root)

        guard let tableScroll = scrollViews.max(by: { $0.bounds.width < $1.bounds.width }) else {
            lines.append("未找到内容区滚动视图（当前页面可能不是文件夹视图）")
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print(lines.joined(separator: "\n"))
            return
        }
        lines.append("内容区滚动视图: \(String(describing: type(of: tableScroll))) 宽度 \(Int(tableScroll.bounds.width))")
        lines.append("全部滚动视图宽度: \(scrollViews.map { Int($0.bounds.width) })")
        lines.append("")

        // 统计表格内的行视图类型（验证 SwiftUI Table 是否使用 NSTableRowView）
        var rowTypes: [String: Int] = [:]
        var cellTypes: [String: Int] = [:]
        var sampleRow: NSView?
        var sampleRowInCell: NSView?
        if let table = tableScroll.documentView {
            func walk(_ view: NSView) {
                let name = String(describing: type(of: view))
                if view is NSTableRowView {
                    rowTypes[name, default: 0] += 1
                    if sampleRow == nil { sampleRow = view }
                }
                if view is NSTableCellView || name.contains("TableCellView") {
                    cellTypes[name, default: 0] += 1
                    if sampleRowInCell == nil { sampleRowInCell = view.subviews.first ?? view }
                }
                for child in view.subviews { walk(child) }
            }
            walk(table)
        }

        lines.append("行视图类型统计: \(rowTypes.isEmpty ? "（未发现行视图）" : "\(rowTypes)")")
        lines.append("单元格类型统计: \(cellTypes.isEmpty ? "（未发现单元格）" : "\(cellTypes)")")
        lines.append("")

        if let row = sampleRow {
            let inRow = EmptyAreaContextMenu.InstallerView.classify(row, in: tableScroll)
            lines.append("行视图 → isOnInteractiveContent = \(inRow)  \(inRow ? "✔ 会交给系统（行菜单）" : "✘ 会被当成空白！")")
        } else {
            lines.append("✘ 未找到行视图：SwiftUI 可能没有使用 NSTableRowView，需要调整判定规则")
        }
        if let inner = sampleRowInCell {
            let inCell = EmptyAreaContextMenu.InstallerView.classify(inner, in: tableScroll)
            lines.append("行内子视图 → isOnInteractiveContent = \(inCell)  \(inCell ? "✔" : "✘ 会被当成空白！")")
        }
        if let table = tableScroll.documentView as? NSTableView {
            let onTable = EmptyAreaContextMenu.InstallerView.classify(table, in: tableScroll)
            lines.append("表格背景（行下方空白）→ isOnInteractiveContent = \(onTable)  \(onTable ? "✘ 不会出背景菜单！" : "✔ 会出背景菜单")")
        }

        let text = lines.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print(text)
    }

    private static func describe(_ view: NSView, depth: Int, into lines: inout [String]) {
        guard depth < 22 else { return }
        let indent = String(repeating: "  ", count: depth)
        var notes: [String] = [String(describing: type(of: view))]
        if view is NSTableRowView { notes.append("rowView") }
        if view is NSTableCellView { notes.append("cell") }
        if view is NSTableView { notes.append("tableView rows=\((view as! NSTableView).numberOfRows)") }
        if view is NSTableHeaderView { notes.append("header") }
        if let scroll = view as? NSScrollView {
            notes.append("scroll document=\(String(describing: type(of: scroll.documentView ?? NSView())))")
        }
        let frame = view.frame
        notes.append("frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))")
        lines.append(indent + notes.joined(separator: " | "))
        for child in view.subviews {
            describe(child, depth: depth + 1, into: &lines)
        }
    }
}
