import AppKit
import SwiftUI

/// Native scrolling keeps each retained row's hosting graph independent. Moving
/// the clip view does not invalidate a SwiftUI tree containing the entire grid.
struct NativeIconGrid: NSViewRepresentable {
    let items: [FileItem]
    let selectedIDs: Set<String>
    let locateIndex: Int?
    let locateRequest: UUID?
    let makeTile: (FileItem) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NativeIconGridScrollView {
        let scroll = NativeIconGridScrollView(frame: .zero)
        context.coordinator.attach(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NativeIconGridScrollView, context: Context) {
        context.coordinator.configure(items: items, selectedIDs: selectedIDs,
            environment: context.environment, makeTile: makeTile,
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

        func configure(items: [FileItem], selectedIDs: Set<String>, environment: EnvironmentValues,
                       makeTile: @escaping (FileItem) -> AnyView, locateIndex: Int?, locateRequest: UUID?) {
            let contentChanged = self.items != items
            let styleChanged = self.environment.locale != environment.locale
                || self.environment.colorScheme != environment.colorScheme
                || self.environment.colorSchemeContrast != environment.colorSchemeContrast
            let oldSelection = self.selectedIDs
            self.items = items
            self.selectedIDs = selectedIDs
            self.environment = environment
            self.makeTile = makeTile
            if contentChanged { removeRows() }
            if let locateRequest, locateRequest != lastLocateRequest,
               let locateIndex, items.indices.contains(locateIndex) {
                pendingLocation = (locateIndex, locateRequest)
            }
            layoutRows()
            for (row, host) in hosts {
                let indices = metrics.indices(row: row)
                if styleChanged || indices.contains(where: { oldSelection.contains(items[$0].id) != selectedIDs.contains(items[$0].id) }) {
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

        private func layoutRows() {
            guard !layingOut, let scroll, let document = scroll.documentView else { return }
            layingOut = true
            defer { layingOut = false }
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
                        host = NSHostingView(rootView: rowView(row))
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
            (document as? NativeIconGridDocumentView)?.refreshHover()
        }
    }
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
final class NativeIconGridDocumentView: NSView {
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
