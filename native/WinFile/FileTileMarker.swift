// 图标视图的磁贴标记
//
// 图标视图使用原生滚动容器与复用行，没有 NSTableView，因此不能使用表格的 doubleAction。
// 这里给每个磁贴挂一个零尺寸的 AppKit 视图，记录它代表的项目与"打开"动作；
// 窗口级鼠标监听在识别到双击时，从这个标记取出项目并执行打开。
import AppKit
import SwiftUI

/// 承载磁贴身份与打开动作的标记视图。
///
/// 它**不参与命中测试**：单击选择、右键菜单仍由 SwiftUI 正常处理；
/// 双击则由窗口级鼠标监听按坐标查找它（用它的 frame 判断点是否落在磁贴上）。
/// 这样既拿到了磁贴位置，又不会抢走 SwiftUI 的交互。
final class FileTileMarkerView: NSView {
    var item: FileItem?
    var onActivate: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 把磁贴的项目与打开动作交给 AppKit 层
struct FileTileMarker: NSViewRepresentable {
    let item: FileItem
    let onActivate: () -> Void

    func makeNSView(context: Context) -> FileTileMarkerView {
        let view = FileTileMarkerView()
        view.item = item
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ view: FileTileMarkerView, context: Context) {
        view.item = item
        view.onActivate = onActivate
    }
}

/// The system centers the 48-point drag preview on its source tile, rather than
/// on the initial mouse-down. Keep that offset so drop targets match the image.
@MainActor
final class DragPreviewGeometry {
    static let shared = DragPreviewGeometry()
    private var monitor: Any?
    private var pendingURL: URL?
    private var pendingID: String?
    private weak var pendingMarker: FileTileMarkerView?
    private weak var pendingDocument: NSView?
    private var pendingDownPoint = NSPoint.zero
    private var pendingOffset = NSPoint.zero
    private var activeOffset = NSPoint.zero
    private var activeURL: URL?
    private(set) var activeSourceID: String?
    private var hiddenSourceTiles: [WeakTile] = []
    private var pendingRestoreTimer: Timer?
    private weak var cachedWindow: NSWindow?
    private weak var cachedScroll: NSScrollView?
    private var cachedBounds = NSRect.null
    private var cachedTargets: [Target] = []
    private(set) var targetScanCount = 0

    private struct Target {
        let frame: NSRect
        let url: URL
        let parent: URL
    }

    private final class WeakTile {
        weak var value: NativeFileTileView?
        init(_ value: NativeFileTileView) { self.value = value }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDragged {
                if let id = self.pendingID, self.activeSourceID != id,
                   hypot(event.locationInWindow.x - self.pendingDownPoint.x,
                         event.locationInWindow.y - self.pendingDownPoint.y) >= 2 {
                    self.hideSourceIcon(id: id)
                    TabDiagnostics.shared.record("grid.drag.lift", detail: "hidden=\(!self.hiddenSourceTiles.isEmpty)")
                    self.startPendingRestoreTimer()
                }
                return event
            }
            if event.type == .leftMouseUp {
                if !DragMoveIndicator.shared.hasPreview { self.restoreSourceIcon() }
                return event
            }
            self.pendingURL = nil
            self.pendingID = nil
            self.pendingMarker = nil
            self.pendingDocument = nil
            guard let window = event.window, let root = window.contentView,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                  let document = hit.enclosingScrollView?.documentView,
                  let marker = EmptyAreaContextMenu.InstallerView.tileMarker(at: event.locationInWindow, in: document),
                  let item = marker.item, item.url.isFileURL else { return event }
            let frame = marker.convert(marker.bounds, to: nil)
            self.pendingURL = item.url.standardizedFileURL
            self.pendingID = item.id
            self.pendingMarker = marker
            self.pendingDocument = document
            self.pendingDownPoint = event.locationInWindow
            self.pendingOffset = NSPoint(x: frame.midX - event.locationInWindow.x,
                                         y: frame.midY - event.locationInWindow.y)
            return event
        }
    }

    func begin(url: URL, customPreview: Bool = false, isDirectory: Bool = false) {
        let expectedID = pendingURL == url.standardizedFileURL ? pendingID : nil
        if activeSourceID != expectedID { restoreSourceIcon() }
        pendingRestoreTimer?.invalidate()
        pendingRestoreTimer = nil
        activeOffset = pendingURL == url.standardizedFileURL ? pendingOffset : .zero
        activeURL = url.standardizedFileURL
        var previewImage: NSImage?
        if let id = expectedID {
            if activeSourceID != id || hiddenSourceTiles.isEmpty { hideSourceIcon(id: id) }
            previewImage = hiddenSourceTiles.compactMap(\.value).first?.dragPreviewImage
            TabDiagnostics.shared.record("grid.drag.sourceVisibility", detail: "hidden=\(!hiddenSourceTiles.isEmpty)")
            if previewImage == nil, let item = pendingMarker?.item {
                previewImage = item.isDirectory ? FileIconService.folderPlaceholder : NSWorkspace.shared.icon(forFile: item.url.path)
            }
        }
        if customPreview {
            let image = previewImage ?? (isDirectory ? FileIconService.folderPlaceholder : NSWorkspace.shared.icon(forFile: url.path))
            DragMoveIndicator.shared.beginPreview(image: image)
        }
        invalidateTargets()
    }

    private func hideSourceIcon(id: String) {
        if activeSourceID != id { restoreSourceIcon() }
        activeSourceID = id
        func findTile(in view: NSView) -> NativeFileTileView? {
            if let tile = view as? NativeFileTileView, tile.represents(id) { return tile }
            for child in view.subviews {
                if let tile = findTile(in: child) { return tile }
            }
            return nil
        }
        var ancestor: NSView? = pendingMarker
        while let view = ancestor {
            if let tile = findTile(in: view) {
                registerHiddenSource(tile, for: id)
                tile.setDragSourceHidden(true, for: id)
                return
            }
            if view === pendingDocument { break }
            ancestor = view.superview
        }
        if let document = pendingDocument, let tile = findTile(in: document) {
            registerHiddenSource(tile, for: id)
            tile.setDragSourceHidden(true, for: id)
        }
    }

    private func startPendingRestoreTimer() {
        guard pendingRestoreTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 && !DragMoveIndicator.shared.hasPreview {
                    self.restoreSourceIcon()
                }
            }
        }
        pendingRestoreTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func isDraggingSource(_ id: String) -> Bool { activeSourceID == id }

    func registerHiddenSource(_ tile: NativeFileTileView, for id: String) {
        guard activeSourceID == id, !hiddenSourceTiles.contains(where: { $0.value === tile }) else { return }
        hiddenSourceTiles.append(WeakTile(tile))
    }

    func restoreSourceIcon() {
        pendingRestoreTimer?.invalidate()
        pendingRestoreTimer = nil
        DragMoveIndicator.shared.endPreview()
        if let id = activeSourceID {
            for tile in hiddenSourceTiles { tile.value?.setDragSourceHidden(false, for: id) }
            TabDiagnostics.shared.record("grid.drag.sourceVisibility", detail: "restored=true")
        }
        hiddenSourceTiles.removeAll()
        activeSourceID = nil
    }

    func invalidateTargets() {
        cachedWindow = nil
        cachedScroll = nil
        cachedTargets.removeAll()
    }

    func previewCenter(local: Bool) -> NSPoint {
        let point = NSEvent.mouseLocation
        return Self.previewCenter(cursor: point, offset: local ? activeOffset : .zero)
    }

    static func previewCenter(cursor: NSPoint, offset: NSPoint) -> NSPoint {
        NSPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)
    }

    static func targetIndex(at point: NSPoint, frames: [NSRect]) -> Int? {
        frames.indices.filter { frames[$0].contains(point) }.min {
            frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height
        }
    }

    func destination(currentDirectory: URL, local: Bool) -> URL? {
        destination(currentDirectory: currentDirectory, center: previewCenter(local: local), excludeSource: local)
    }

    func destination(currentDirectory: URL, center: NSPoint, excludeSource: Bool = true) -> URL? {
        let window: NSWindow
        if let cachedWindow, cachedWindow.isVisible, !cachedWindow.ignoresMouseEvents,
           cachedWindow.frame.contains(center), cachedWindow.contentView != nil {
            window = cachedWindow
        } else {
            guard let candidate = NSApp.orderedWindows.first(where: { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(center) && $0.contentView != nil }) else { return nil }
            window = candidate
        }
        guard let root = window.contentView else { return nil }
        let scrollChanged = cachedScroll.map { $0.window !== window || $0.contentView.bounds != cachedBounds } ?? false
        if cachedWindow !== window || scrollChanged {
            cachedWindow = window
            targetScanCount += 1
            var found: [Target] = []
            var scroll: NSScrollView?
            func collect(_ view: NSView) {
                guard !view.isHidden else { return }
                if let marker = view as? FileTileMarkerView, let item = marker.item {
                    if scroll == nil { scroll = marker.enclosingScrollView }
                    guard item.isDirectory, !item.isBundle, item.url.isFileURL else { return }
                    var frame = marker.convert(marker.bounds, to: nil)
                    var ancestor = marker.superview
                    while let view = ancestor {
                        if view is NSClipView { frame = frame.intersection(view.convert(view.bounds, to: nil)) }
                        ancestor = view.superview
                    }
                    if !frame.isNull && !frame.isEmpty {
                        found.append(Target(frame: frame, url: item.url.standardizedFileURL, parent: item.url.deletingLastPathComponent().standardizedFileURL))
                    }
                    return
                }
                for child in view.subviews { collect(child) }
            }
            collect(root)
            cachedTargets = found
            cachedScroll = scroll
            cachedBounds = cachedScroll?.contentView.bounds ?? .null
        }
        let point = window.convertPoint(fromScreen: center)
        let directory = currentDirectory.standardizedFileURL.path
        var best: Target?
        for target in cachedTargets where target.parent.path == directory && target.frame.contains(point) {
            if excludeSource && target.url == activeURL { continue }
            if best == nil || target.frame.width * target.frame.height < best!.frame.width * best!.frame.height { best = target }
        }
        return best?.url
    }
}
