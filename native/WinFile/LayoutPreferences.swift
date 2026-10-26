import AppKit

/// Keep preferred pane widths when the window temporarily becomes narrower.
enum PaneLayout {
    static let sidebarKey = "Layout.SidebarWidth"
    static let inspectorKey = "Layout.InspectorWidth"
    static let divider: CGFloat = 12

    static func widths(total: CGFloat, sidebar: Double, inspector: Double, showsInspector: Bool,
                       showsSidebar: Bool = true) -> (sidebar: CGFloat, inspector: CGFloat) {
        let side = showsSidebar ? min(360, max(160, sidebar.isFinite ? sidebar : 216)) : 0
        let detail = showsInspector ? min(420, max(200, inspector.isFinite ? inspector : 264)) : 0
        let dividerCount = (showsSidebar ? 1 : 0) + (showsInspector ? 1 : 0)
        let budget = max(0, total - 400 - divider * CGFloat(dividerCount))
        guard side + detail > budget else { return (side, detail) }
        let minimumSide = showsSidebar ? 160.0 : 0
        let minimumDetail = showsInspector ? 200.0 : 0
        let minimum = minimumSide + minimumDetail
        if budget < minimum {
            let ratio = budget / minimum
            return (minimumSide * ratio, minimumDetail * ratio)
        }
        let flexibility = side - minimumSide + detail - minimumDetail
        let ratio = flexibility > 0 ? (budget - minimum) / flexibility : 0
        return (minimumSide + (side - minimumSide) * ratio,
                minimumDetail + (detail - minimumDetail) * ratio)
    }
}

/// Store only user-resized widths, independently of SwiftUI's localized column identifiers.
/// Keeping sort descriptors out of this store leaves the model as the sorting authority.
@MainActor
final class TableColumnPreferences: NSObject {
    private static var association: UInt8 = 0
    private weak var table: NSTableView?
    private let defaults: UserDefaults
    private let key: String
    private let userResize: (NSTableView) -> Bool
    private var observer: NSObjectProtocol?

    static func install(on table: NSTableView, kind: String, defaults: UserDefaults = .standard) {
        guard !isInstalled(on: table, kind: kind) else { return }
        let controller = TableColumnPreferences(table: table, kind: kind, defaults: defaults)
        objc_setAssociatedObject(table, &association, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func isInstalled(on table: NSTableView, kind: String) -> Bool {
        (objc_getAssociatedObject(table, &association) as? TableColumnPreferences)?.key == "Layout.Columns.\(kind).v1"
    }

    init(table: NSTableView, kind: String, defaults: UserDefaults, userResize: ((NSTableView) -> Bool)? = nil) {
        self.table = table
        self.defaults = defaults
        key = "Layout.Columns.\(kind).v1"
        self.userResize = userResize ?? Self.isUserResizing
        super.init()
        restore()
        let resizeNotification = table is NSOutlineView ? NSOutlineView.columnDidResizeNotification : NSTableView.columnDidResizeNotification
        observer = NotificationCenter.default.addObserver(forName: resizeNotification,
                                                          object: table, queue: .main) { [weak self] _ in
            // Automatic layout also emits this notification. It must not overwrite the
            // user's preferred widths when a small window compresses the table.
            MainActor.assumeIsolated {
                guard let self, let table = self.table, self.userResize(table) else { return }
                // AppKit can announce a resize only after mouseUp, when pressedMouseButtons is already zero.
                self.save()
            }
        }
    }

    private static func isUserResizing(_ table: NSTableView) -> Bool {
        guard table.window?.inLiveResize != true, let event = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
              event.window === table.window, let header = table.headerView else { return false }
        return header.bounds.insetBy(dx: -8, dy: -8).contains(header.convert(event.locationInWindow, from: nil))
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func save() {
        guard let table else { return }
        defaults.set(table.tableColumns.map { Double($0.width) }, forKey: key)
    }

    private func restore() {
        guard let table, let values = defaults.array(forKey: key) as? [Double],
              values.count == table.tableColumns.count else { return }
        for (column, width) in zip(table.tableColumns, values) where width.isFinite && width > 0 {
            column.width = min(column.maxWidth, max(column.minWidth, width))
        }
    }
}

/// Shared geometry for a windowed icon grid. Only the viewport plus two spare
/// rows at either end create tile views; content height remains stable while scrolling.
struct IconGridMetrics {
    static let padding: CGFloat = 14
    static let pitch: CGFloat = 116
    let count: Int
    let columns: Int
    init(count: Int, width: CGFloat) {
        self.count = max(0, count)
        columns = max(1, min(8, Int(max(0, width - Self.padding * 2 + 10) / 114)))
    }
    var rows: Int { (count + columns - 1) / columns }
    var height: CGFloat { CGFloat(rows) * Self.pitch + Self.padding * 2 }
    func visibleRows(offset: CGFloat, viewport: CGFloat) -> Range<Int> {
        let start = min(rows, max(0, Int(max(0, offset - Self.padding) / Self.pitch) - 2))
        let end = min(rows, max(start, Int(ceil((max(0, offset) + max(0, viewport)) / Self.pitch)) + 2))
        return start..<end
    }
    func indices(row: Int) -> Range<Int> {
        let start = min(count, max(0, row * columns))
        return start..<min(count, start + columns)
    }
}
