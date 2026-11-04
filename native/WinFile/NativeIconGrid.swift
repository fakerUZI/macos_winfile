import AppKit
import SwiftUI

/// Native scrolling keeps each retained row's hosting graph independent. Moving
/// the clip view does not invalidate a SwiftUI tree containing the entire grid.
struct NativeIconGrid: NSViewRepresentable {
    let items: [FileItem]
    let selectedIDs: Set<String>
    var cutIDs: Set<String> = []
    var positions: [String: CGPoint] = [:]
    var onScrollOffset: (CGPoint) -> Void = { _ in }
    let locateIndex: Int?
    let locateRequest: UUID?
    let makeTile: (FileItem) -> AnyView
    var onNativeDragUpdate: ((NSDraggingInfo) -> NSDragOperation)? = nil
    var onNativeDragExit: (() -> Void)? = nil
    var onNativeDragPrepare: ((NSDraggingInfo) -> Void)? = nil
    var onNativeSourceMove: ((NSPoint?) -> Void)? = nil
    var onNativeSourceEnd: (() -> Void)? = nil
    var onNativeDrop: ((NSDraggingInfo, NSPoint) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NativeIconGridScrollView {
        let scroll = NativeIconGridScrollView(frame: .zero)
        context.coordinator.attach(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NativeIconGridScrollView, context: Context) {
        if let document = scroll.documentView as? NativeIconGridDocumentView {
            document.configureDrop(update: onNativeDragUpdate, exit: onNativeDragExit, prepare: onNativeDragPrepare,
                                   sourceMove: onNativeSourceMove, sourceEnd: onNativeSourceEnd, perform: onNativeDrop)
        }
        context.coordinator.configure(items: items, selectedIDs: selectedIDs, cutIDs: cutIDs, positions: positions,
            onScrollOffset: onScrollOffset, environment: context.environment, makeTile: makeTile,
            locateIndex: locateIndex, locateRequest: locateRequest)
    }
    static func dismantleNSView(_ scroll: NativeIconGridScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var scroll: NativeIconGridScrollView?
        private var observer: NSObjectProtocol?
        private var items: [FileItem] = []
        private var selectedIDs: Set<String> = []
        private var cutIDs: Set<String> = []
        private var positions: [String: CGPoint] = [:]
        private var onScrollOffset: (CGPoint) -> Void = { _ in }
        private var freeFrames: [NSRect] = []
        private var freeBuckets: [Int: [Int]] = [:]
        private var freeLayoutWidth: CGFloat = -1
        private var freeContentHeight: CGFloat = 0
        private var previousWasFree = false
        private var environment = EnvironmentValues()
        private var makeTile: ((FileItem) -> AnyView)?
        private var hosts: [Int: NSHostingView<AnyView>] = [:]
        private var spareHosts: [NSHostingView<AnyView>] = []
        private var metrics = IconGridMetrics(count: 0, width: 0)
        private var rowWidth: CGFloat = 0
        private var lastLocateRequest: UUID?
        private var pendingLocation: (index: Int, request: UUID)?
        private var layingOut = false

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func attach(_ scroll: NativeIconGridScrollView) {
            self.scroll = scroll
            scroll.onResize = { [weak self] in self?.layoutRows() }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutRows() }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scroll?.onResize = nil
            removeRows()
            makeTile = nil
            scroll = nil
        }

        func configure(items: [FileItem], selectedIDs: Set<String>, cutIDs: Set<String> = [], positions: [String: CGPoint] = [:], onScrollOffset: @escaping (CGPoint) -> Void = { _ in }, environment: EnvironmentValues,
                       makeTile: @escaping (FileItem) -> AnyView, locateIndex: Int?, locateRequest: UUID?) {
            let contentChanged = self.items != items
            let positionsChanged = self.positions != positions
            let modeChanged = previousWasFree != !positions.isEmpty
            previousWasFree = !positions.isEmpty
            self.positions = positions
            self.onScrollOffset = onScrollOffset
            if contentChanged || positionsChanged || modeChanged { freeLayoutWidth = -1 }
            if modeChanged { removeRows() }
            let styleChanged = self.environment.locale != environment.locale
                || self.environment.colorScheme != environment.colorScheme
                || self.environment.colorSchemeContrast != environment.colorSchemeContrast
            let oldSelection = self.selectedIDs
            let oldCutIDs = self.cutIDs
            self.items = items
            self.selectedIDs = selectedIDs
            self.cutIDs = cutIDs
            self.environment = environment
            self.makeTile = makeTile
            if contentChanged { removeRows() }
            if let locateRequest, locateRequest != lastLocateRequest,
               let locateIndex, items.indices.contains(locateIndex) {
                pendingLocation = (locateIndex, locateRequest)
            }
            layoutRows()
            if !positions.isEmpty {
                for (index, host) in hosts where items.indices.contains(index) {
                    if contentChanged || positionsChanged || styleChanged || oldSelection.contains(items[index].id) != selectedIDs.contains(items[index].id) || oldCutIDs.contains(items[index].id) != cutIDs.contains(items[index].id) {
                        host.rootView = freeItemView(index)
                    }
                }
                return
            }
            for (row, host) in hosts {
                let indices = metrics.indices(row: row)
                if styleChanged || indices.contains(where: { oldSelection.contains(items[$0].id) != selectedIDs.contains(items[$0].id) || oldCutIDs.contains(items[$0].id) != cutIDs.contains(items[$0].id) }) {
                    host.rootView = rowView(row)
                }
            }
        }

        private func removeRows() {
            for host in hosts.values { host.removeFromSuperview() }
            for host in spareHosts { host.removeFromSuperview() }
            hosts.removeAll()
            spareHosts.removeAll()
        }

        private func rowView(_ row: Int) -> AnyView {
            guard let makeTile else { return AnyView(EmptyView()) }
            let indices = metrics.indices(row: row)
            let rowItems = indices.map { items[$0] }
            return AnyView(HStack(alignment: .top, spacing: 10) {
                ForEach(0..<rowItems.count, id: \.self) { slot in
                    makeTile(rowItems[slot]).frame(maxWidth: .infinity)
                        .frame(height: IconGridMetrics.pitch - 10, alignment: .top)
                }
                ForEach(0..<(metrics.columns - indices.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .frame(width: rowWidth, height: IconGridMetrics.pitch - 10, alignment: .top)
            .environment(\.self, environment))
        }

        private func freeItemView(_ index: Int) -> AnyView {
            guard let makeTile, items.indices.contains(index) else { return AnyView(EmptyView()) }
            return AnyView(makeTile(items[index]).frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.self, environment))
        }

        private func layoutFreeItems(in scroll: NativeIconGridScrollView, document: NSView) {
            let width = max(1, scroll.contentSize.width)
            let nextMetrics = IconGridMetrics(count: items.count, width: width)
            let cellWidth = max(1, (width - IconGridMetrics.padding * 2 - CGFloat(nextMetrics.columns - 1) * 10) / CGFloat(nextMetrics.columns))
            let height = IconGridMetrics.pitch - 10
            if freeLayoutWidth != width || freeFrames.count != items.count {
                freeLayoutWidth = width
                freeBuckets.removeAll()
                freeFrames = items.enumerated().map { index, item in
                    let standard = CGPoint(x: IconGridMetrics.padding + CGFloat(index % nextMetrics.columns) * (cellWidth + 10),
                                           y: IconGridMetrics.padding + CGFloat(index / nextMetrics.columns) * IconGridMetrics.pitch)
                    let position = positions[item.id] ?? standard
                    let frame = NSRect(x: min(max(0, position.x), max(0, width - cellWidth)), y: max(0, position.y), width: cellWidth, height: height)
                    let first = Int(frame.minY / IconGridMetrics.pitch)
                    let last = Int(frame.maxY / IconGridMetrics.pitch)
                    for row in first...last { freeBuckets[row, default: []].append(index) }
                    return frame
                }
                freeContentHeight = (freeFrames.map(\.maxY).max() ?? 0) + IconGridMetrics.padding
            }
            let totalHeight = max(scroll.contentSize.height, freeContentHeight)
            let size = NSSize(width: width, height: totalHeight)
            if document.frame.size != size { document.setFrameSize(size) }
            if let target = pendingLocation, items.indices.contains(target.index) {
                let frame = freeFrames[target.index]
                let y = min(max(0, size.height - scroll.contentSize.height), max(0, frame.midY - scroll.contentSize.height / 2))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                lastLocateRequest = target.request; pendingLocation = nil
            }
            let visibleRect = scroll.contentView.bounds.insetBy(dx: 0, dy: -IconGridMetrics.pitch * 2)
            let first = max(0, Int(visibleRect.minY / IconGridMetrics.pitch))
            let last = max(first, Int(visibleRect.maxY / IconGridMetrics.pitch))
            let visible = Set((first...last).flatMap { freeBuckets[$0] ?? [] }.filter { freeFrames[$0].intersects(visibleRect) })
            for index in Array(hosts.keys) where !visible.contains(index) {
                if let host = hosts.removeValue(forKey: index) { host.isHidden = true; spareHosts.append(host) }
            }
            for index in visible {
                let host: NSHostingView<AnyView>
                if let existing = hosts[index] { host = existing }
                else {
                    host = spareHosts.popLast() ?? NativeIconGridRowHost(rootView: freeItemView(index))
                    host.rootView = freeItemView(index)
                    host.sizingOptions = []
                    if host.superview == nil { document.addSubview(host); scroll.createdRowHosts += 1 }
                    host.isHidden = false; hosts[index] = host
                }
                if host.frame != freeFrames[index] { host.frame = freeFrames[index] }
            }
            while spareHosts.count > 4 { spareHosts.removeLast().removeFromSuperview() }
            (document as? NativeIconGridDocumentView)?.ensureDropSurfaceOnTop()
            (document as? NativeIconGridDocumentView)?.refreshHover()
        }

        private func layoutRows() {
            guard !layingOut, let scroll, let document = scroll.documentView else { return }
            layingOut = true
            defer { layingOut = false }
            let offset = scroll.contentView.bounds.origin
            DispatchQueue.main.async { [weak self] in self?.onScrollOffset(offset) }
            if !positions.isEmpty { layoutFreeItems(in: scroll, document: document); return }
            let width = max(0, scroll.contentSize.width)
            let next = IconGridMetrics(count: items.count, width: width)
            let nextRowWidth = max(1, width - IconGridMetrics.padding * 2)
            let geometryChanged = metrics.columns != next.columns || rowWidth != nextRowWidth
            metrics = next
            rowWidth = nextRowWidth
            let size = NSSize(width: width, height: max(scroll.contentSize.height, metrics.height))
            if document.frame.size != size { document.setFrameSize(size) }
            let bounds = scroll.contentView.bounds
            var y = min(max(0, bounds.minY), max(0, size.height - bounds.height))
            if width > 0, bounds.height > 0, let target = pendingLocation, items.indices.contains(target.index) {
                let center = IconGridMetrics.padding + CGFloat(target.index / metrics.columns) * IconGridMetrics.pitch + IconGridMetrics.pitch / 2
                y = min(max(0, size.height - bounds.height), max(0, center - bounds.height / 2))
                lastLocateRequest = target.request
                pendingLocation = nil
            }
            if y != bounds.minY {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let visible = metrics.visibleRows(offset: y, viewport: bounds.height)
            for row in Array(hosts.keys) where !visible.contains(row) {
                if let host = hosts.removeValue(forKey: row) {
                    host.isHidden = true
                    spareHosts.append(host)
                }
            }
            for row in visible {
                let frame = NSRect(x: IconGridMetrics.padding,
                    y: IconGridMetrics.padding + CGFloat(row) * IconGridMetrics.pitch,
                    width: rowWidth, height: IconGridMetrics.pitch - 10)
                if let host = hosts[row] {
                    if geometryChanged { host.rootView = rowView(row) }
                    if host.frame != frame { host.frame = frame }
                } else {
                    let host: NSHostingView<AnyView>
                    if let reused = spareHosts.popLast() {
                        host = reused
                        host.rootView = rowView(row)
                    } else {
                        host = NativeIconGridRowHost(rootView: rowView(row))
                        host.sizingOptions = []
                        document.addSubview(host)
                        scroll.createdRowHosts += 1
                    }
                    host.frame = frame
                    host.isHidden = false
                    host.layoutSubtreeIfNeeded()
                    hosts[row] = host
                }
            }
            while spareHosts.count > 4 { spareHosts.removeLast().removeFromSuperview() }
            (document as? NativeIconGridDocumentView)?.ensureDropSurfaceOnTop()
            (document as? NativeIconGridDocumentView)?.refreshHover()
        }
    }
}

/// The hosting rows cover file icons and labels. Forward drag events to the
/// document so moving across a row cannot lose the active drop destination.
final class NativeIconGridRowHost: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var gridDocument: NativeIconGridDocumentView? {
        enclosingScrollView?.documentView as? NativeIconGridDocumentView
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        gridDocument?.draggingEntered(sender) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        gridDocument?.draggingUpdated(sender) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { gridDocument?.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        gridDocument?.prepareForDragOperation(sender) ?? false
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        gridDocument?.performDragOperation(sender) ?? false
    }
}

/// Only participates in hit testing during a local grid drag. This keeps the
/// destination stable while the pointer crosses hosted SwiftUI rows and tiles.
final class NativeIconGridDropSurface: NSView {
    weak var document: NativeIconGridDocumentView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard DragMoveIndicator.shared.hasPreview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { document?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { document?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { document?.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { document?.prepareForDragOperation(sender) ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { document?.performDragOperation(sender) ?? false }
}

final class NativeIconGridScrollView: NSScrollView {
    var onResize: (() -> Void)?
    fileprivate(set) var createdRowHosts = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = .init()
        wantsLayer = true
        let document = NativeIconGridDocumentView(frame: .zero)
        document.wantsLayer = true
        documentView = document
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func tile() {
        super.tile()
        onResize?()
    }
}
@MainActor
private final class NativeIconGridDragSource: NSObject, NSDraggingSource {
    weak var document: NativeIconGridDocumentView?
    init(document: NativeIconGridDocumentView) { self.document = document }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        document?.nativeSourceMoved(to: screenPoint)
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        document?.nativeSourceMoved(to: screenPoint)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if ProcessInfo.processInfo.environment["WINFILE_DRAG_GEOMETRY"] == "1" {
            TabDiagnostics.shared.record("grid.source.drag.end", detail: "operation=\(operation.rawValue)")
        }
        document?.nativeSourceEnded()
    }
}

final class NativeIconGridDocumentView: NSView {
    private lazy var dropSurface: NativeIconGridDropSurface = {
        let view = NativeIconGridDropSurface(frame: bounds)
        view.document = self
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.zPosition = 10000
        return view
    }()
    private var dragUpdate: ((NSDraggingInfo) -> NSDragOperation)?
    private var dragExit: (() -> Void)?
    private var dragPrepare: ((NSDraggingInfo) -> Void)?
    private var sourceMove: ((NSPoint?) -> Void)?
    private var sourceEnd: (() -> Void)?
    private var activeDragSource: NativeIconGridDragSource?
    private var drop: ((NSDraggingInfo, NSPoint) -> Bool)?
    private var acceptsFileDrops = false

    func configureDrop(update: ((NSDraggingInfo) -> NSDragOperation)?, exit: (() -> Void)?,
                       prepare: ((NSDraggingInfo) -> Void)?, sourceMove: ((NSPoint?) -> Void)? = nil,
                       sourceEnd: (() -> Void)? = nil, perform: ((NSDraggingInfo, NSPoint) -> Bool)?) {
        dragUpdate = update
        dragExit = exit
        dragPrepare = prepare
        self.sourceMove = sourceMove
        self.sourceEnd = sourceEnd
        drop = perform
        let enabled = update != nil && perform != nil
        if enabled != acceptsFileDrops {
            acceptsFileDrops = enabled
            if enabled {
                registerForDraggedTypes([.fileURL])
                addSubview(dropSurface, positioned: .above, relativeTo: nil)
            } else {
                unregisterDraggedTypes()
                dropSurface.removeFromSuperview()
            }
        }
    }

    /// Start an AppKit drag so position and completion come from one session,
    /// even when destination views send transient exit/enter events.
    func beginNativeDrag(item: FileItem, mouseDown: NSEvent) -> Bool {
        guard activeDragSource == nil, window != nil, sourceMove != nil,
              let pasteboardItem = SidebarFolderDrop.nativePasteboardItem(for: item) else { return false }
        let source = NativeIconGridDragSource(document: self)
        activeDragSource = source
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let origin = convert(mouseDown.locationInWindow, from: nil)
        let icon = item.isDirectory ? FileIconService.folderPlaceholder : NSWorkspace.shared.icon(forFile: item.url.path)
        func image(_ scissors: Bool) -> NSImage {
            NSImage(size: NSSize(width: 112, height: 76), flipped: false) { _ in
                icon.draw(in: NSRect(x: 32, y: 28, width: 48, height: 48))
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byTruncatingMiddle
                (item.name as NSString).draw(in: NSRect(x: 0, y: 1, width: 112, height: 24), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ])
                if scissors, let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
                    symbol.draw(in: NSRect(x: 62, y: 28, width: 18, height: 18))
                }
                return true
            }
        }
        let plainImage = image(false)
        let moveImage = image(true)
        draggingItem.setDraggingFrame(NSRect(x: origin.x - 56, y: origin.y - 24, width: 112, height: 76),
                                      contents: plainImage)
        let session = beginDraggingSession(with: [draggingItem], event: mouseDown, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
        DragMoveIndicator.shared.nativePreviewUpdater = { [weak self, weak session] scissors in
            DispatchQueue.main.async {
                guard DragPreviewGeometry.shared.usesManagedDrag, let self, let session else { return }
                let preview = scissors ? moveImage : plainImage
                session.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { draggingItem, _, _ in
                    draggingItem.imageComponentsProvider = {
                        let component = NSDraggingImageComponent(key: .icon)
                        component.contents = preview
                        component.frame = NSRect(x: 0, y: 0, width: 112, height: 76)
                        return [component]
                    }
                }
            }
        }
        return true
    }

    fileprivate func nativeSourceMoved(to screenPoint: NSPoint) {
        guard DragPreviewGeometry.shared.usesManagedDrag, let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard visibleRect.contains(point) else {
            sourceMove?(nil)
            return
        }
        DragMoveIndicator.shared.positionOverlay(screenCenter: screenPoint)
        sourceMove?(screenPoint)
    }

    fileprivate func nativeSourceEnded() {
        sourceEnd?()
        DragPreviewGeometry.shared.restoreSourceIcon()
        activeDragSource = nil
    }

    /// NSView hit testing follows subview order, independently of layer
    /// zPosition. Rows created after the surface must not cover its hit area.
    func ensureDropSurfaceOnTop() {
        guard acceptsFileDrops, dropSurface.superview === self, subviews.last !== dropSurface else { return }
        dropSurface.removeFromSuperview()
        addSubview(dropSurface, positioned: .above, relativeTo: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ProcessInfo.processInfo.environment["WINFILE_DRAG_GEOMETRY"] == "1" {
            TabDiagnostics.shared.record("grid.native.drag.enter")
        }
        DragPreviewGeometry.shared.invalidateTargets()
        return dragUpdate?(sender) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragUpdate?(sender) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if ProcessInfo.processInfo.environment["WINFILE_DRAG_GEOMETRY"] == "1" {
            TabDiagnostics.shared.record("grid.native.drag.exit")
        }
        dragExit?()
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = dragUpdate?(sender).isEmpty == false && drop != nil
        if accepted { dragPrepare?(sender) }
        TabDiagnostics.shared.record("grid.native.drag.prepare", detail: "accepted=\(accepted)")
        return accepted
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let documentPoint = convert(sender.draggingLocation, from: nil)
        let visibleOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        let point = NSPoint(x: documentPoint.x - visibleOrigin.x, y: documentPoint.y - visibleOrigin.y)
        return drop?(sender, point) ?? false
    }
    private var tracking: NSTrackingArea?
    private(set) weak var hoveredTile: NativeFileTileView?
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { updateHover(at: nil) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    func refreshHover() {
        guard let window, window.isKeyWindow else { updateHover(at: nil); return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func updateHover(at point: NSPoint?) {
        let tile: NativeFileTileView? = point.flatMap {
            visibleRect.contains($0) ? self.tile(at: $0, in: self) : nil
        }
        if hoveredTile !== tile {
            hoveredTile?.setHovering(false)
            hoveredTile = tile
        }
        // Reapply even when the view identity is unchanged: its file may have
        // changed during row reuse, which resets the tile's transient state.
        tile?.setHovering(true)
    }

    private func tile(at point: NSPoint, in view: NSView) -> NativeFileTileView? {
        guard !view.isHidden, view.bounds.contains(view.convert(point, from: self)) else { return nil }
        if let tile = view as? NativeFileTileView { return tile }
        for child in view.subviews {
            if let tile = tile(at: point, in: child) { return tile }
        }
        return nil
    }
}
