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

/// Keep the preview aligned with the source icon, including when the drag
/// begins on an edge or on its filename.
@MainActor
final class DragPreviewGeometry {
    static let shared = DragPreviewGeometry()
    private var monitor: Any?
    private var pendingURL: URL?
    private var pendingID: String?
    private var pendingItem: FileItem?
    private var pendingDownEvent: NSEvent?
    private weak var pendingMarker: FileTileMarkerView?
    private weak var pendingDocument: NSView?
    private var pendingDownPoint = NSPoint.zero
    private var pendingOffset = NSPoint.zero
    private var activeOffset = NSPoint.zero
    private var activeURLID: String?
    private var usesCustomPreview = false
    private(set) var usesManagedDrag = false
    private var cachedDirectoryURL: URL?
    private var cachedDirectoryID: String?
    private(set) var activeSourceID: String?
    private var hiddenSourceTiles: [WeakTile] = []
    private weak var cachedWindow: NSWindow?
    private weak var cachedScroll: NSScrollView?
    private var cachedBounds = NSRect.null
    private var cachedTargets: [Target] = []
    private(set) var targetScanCount = 0

    private struct Target {
        let frame: NSRect
        var iconFrame: NSRect?
        let url: URL
        let id: String
        let parentID: String
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
                if let item = self.pendingItem, let downEvent = self.pendingDownEvent,
                   let document = self.pendingDocument as? NativeIconGridDocumentView,
                   hypot(event.locationInWindow.x - self.pendingDownPoint.x,
                         event.locationInWindow.y - self.pendingDownPoint.y) >= 2,
                   document.beginNativeDrag(item: item, mouseDown: downEvent) {
                    self.pendingDownEvent = nil
                    return nil
                }
                return event
            }
            if event.type == .leftMouseUp {
                self.pendingDownEvent = nil
                if !DragMoveIndicator.shared.hasPreview { self.restoreSourceIcon() }
                return event
            }
            self.pendingURL = nil
            self.pendingID = nil
            self.pendingItem = nil
            self.pendingDownEvent = nil
            self.pendingMarker = nil
            self.pendingDocument = nil
            guard let window = event.window, let root = window.contentView,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                  let document = hit.enclosingScrollView?.documentView,
                  let marker = EmptyAreaContextMenu.InstallerView.tileMarker(at: event.locationInWindow, in: document),
                  let item = marker.item, item.url.isFileURL else { return event }
            let frame = marker.convert(marker.bounds, to: nil)
            func findIcon(in view: NSView) -> NSRect? {
                guard !view.isHidden else { return nil }
                if let tile = view as? NativeFileTileView, tile.represents(item.id) {
                    let icon = tile.iconFrameInWindow
                    return icon.isEmpty ? nil : icon
                }
                for child in view.subviews {
                    if let icon = findIcon(in: child) { return icon }
                }
                return nil
            }
            let icon = findIcon(in: document)
            self.pendingURL = item.url.standardizedFileURL
            self.pendingID = item.id
            self.pendingItem = item
            self.pendingDownEvent = event
            self.pendingMarker = marker
            self.pendingDocument = document
            self.pendingDownPoint = event.locationInWindow
            self.pendingOffset = Self.previewOffset(icon: icon, tile: frame, mouseDown: event.locationInWindow)
            return event
        }
    }

    func begin(url: URL, customPreview: Bool = false, isDirectory: Bool = false, managedSession: Bool = false) {
        let expectedID = pendingURL == url.standardizedFileURL ? pendingID : nil
        if activeSourceID != expectedID { restoreSourceIcon() }
        activeOffset = pendingURL == url.standardizedFileURL ? pendingOffset : .zero
        activeURLID = FileItem.canonicalID(for: url)
        var previewImage: NSImage?
        if let id = expectedID {
            if activeSourceID != id || hiddenSourceTiles.isEmpty { hideSourceIcon(id: id) }
            previewImage = hiddenSourceTiles.compactMap(\.value).first?.dragPreviewImage
            TabDiagnostics.shared.record("grid.drag.sourceVisibility", detail: "hidden=\(!hiddenSourceTiles.isEmpty)")
            if previewImage == nil, let item = pendingMarker?.item {
                previewImage = item.isDirectory ? FileIconService.folderPlaceholder : NSWorkspace.shared.icon(forFile: item.url.path)
            }
        }
        // Hiding a new source may restore the previous source, which clears the
        // session flags. Set them only after that cleanup has finished.
        usesCustomPreview = customPreview
        usesManagedDrag = managedSession
        if customPreview {
            let image = previewImage ?? (isDirectory ? FileIconService.folderPlaceholder : NSWorkspace.shared.icon(forFile: url.path))
            DragMoveIndicator.shared.beginPreview(image: image, name: pendingMarker?.item?.name ?? url.lastPathComponent,
                                                  managedSession: managedSession)
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

    func isDraggingSource(_ id: String) -> Bool { activeSourceID == id }

    func registerHiddenSource(_ tile: NativeFileTileView, for id: String) {
        guard activeSourceID == id, !hiddenSourceTiles.contains(where: { $0.value === tile }) else { return }
        hiddenSourceTiles.append(WeakTile(tile))
    }

    func restoreSourceIcon() {
        usesManagedDrag = false
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
        cachedDirectoryURL = nil
        cachedDirectoryID = nil
    }

    func previewCenter(local: Bool) -> NSPoint {
        previewCenter(cursor: NSEvent.mouseLocation, local: local)
    }

    func previewCenter(cursor: NSPoint, local: Bool) -> NSPoint {
        Self.previewCenter(cursor: cursor, offset: local ? activeOffset : .zero)
    }

    static func previewCenter(cursor: NSPoint, offset: NSPoint) -> NSPoint {
        NSPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)
    }

    static func previewOffset(icon: NSRect?, tile: NSRect, mouseDown: NSPoint) -> NSPoint {
        let hitRect = folderIconHitRect(icon: icon, tile: tile)
        let center = hitRect.isNull || hitRect.isEmpty ? NSPoint(x: tile.midX, y: tile.midY) : NSPoint(x: hitRect.midX, y: hitRect.midY)
        return NSPoint(x: center.x - mouseDown.x, y: center.y - mouseDown.y)
    }

    static func targetIndex(at point: NSPoint, frames: [NSRect]) -> Int? {
        frames.indices.filter { frames[$0].contains(point) }.min {
            frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height
        }
    }

    func destination(currentDirectory: URL, local: Bool, cursor eventCursor: NSPoint? = nil) -> URL? {
        let cursor = eventCursor ?? NSEvent.mouseLocation
        let computedPreview = Self.previewCenter(cursor: cursor, offset: local ? activeOffset : .zero)
        // For our own grid preview, the displayed icon is the visual contract.
        // The pointer can be offset when the user grabs an icon edge or its name;
        // combining both positions produces a larger, misleading target area.
        let customPreview = local && usesCustomPreview
        let visiblePreview = customPreview ? DragMoveIndicator.shared.lastDisplayedCenter : nil
        return destination(currentDirectory: currentDirectory,
                           preview: visiblePreview ?? computedPreview,
                           cursor: cursor, excludeSource: local,
                           allowCursorFallback: !customPreview, allowIconOverlap: customPreview)
    }

    func destination(currentDirectory: URL, preview: NSPoint, cursor: NSPoint,
                     excludeSource: Bool = true, allowCursorFallback: Bool = true,
                     allowIconOverlap: Bool = false) -> URL? {
        if let target = destination(currentDirectory: currentDirectory, center: preview, excludeSource: excludeSource) {
            return target
        }
        if allowIconOverlap, let target = overlappingIconDestination(currentDirectory: currentDirectory, preview: preview, excludeSource: excludeSource) {
            return target
        }
        guard allowCursorFallback, cursor != preview else { return nil }
        return destination(currentDirectory: currentDirectory, center: cursor, excludeSource: excludeSource)
    }

    static func folderIconHitRect(icon: NSRect?, tile: NSRect) -> NSRect {
        let fallback = NSRect(x: tile.midX - 22, y: tile.maxY - 50, width: 44, height: 44)
        return (icon ?? fallback).intersection(tile)
    }

    /// Accept a visible overlap above the folder, but do not extend the target
    /// down into the filename even when the dragged image still touches it.
    static func folderOverlapArea(previewCenter: NSPoint, icon: NSRect) -> CGFloat {
        guard !icon.isNull, !icon.isEmpty, previewCenter.y >= icon.minY else { return 0 }
        let draggedIcon = NSRect(x: previewCenter.x - 24, y: previewCenter.y - 24, width: 48, height: 48)
        let overlap = draggedIcon.intersection(icon)
        guard !overlap.isNull, !overlap.isEmpty else { return 0 }
        let area = overlap.width * overlap.height
        return area >= icon.width * icon.height * 0.1 ? area : 0
    }

    private func overlappingIconDestination(currentDirectory: URL, preview: NSPoint, excludeSource: Bool) -> URL? {
        guard let window = cachedWindow, cachedDirectoryURL == currentDirectory, let directory = cachedDirectoryID else { return nil }
        let point = window.convertPoint(fromScreen: preview)
        return cachedTargets.filter { $0.parentID == directory && (!excludeSource || $0.id != activeURLID) }
            .compactMap { target -> (URL, CGFloat)? in
                let icon = Self.folderIconHitRect(icon: target.iconFrame, tile: target.frame)
                let area = Self.folderOverlapArea(previewCenter: point, icon: icon)
                return area > 0 ? (target.url, area) : nil
            }.max { $0.1 < $1.1 }?.0
    }

    func diagnosticOffsets(currentDirectory: URL, local: Bool, eventCursor: NSPoint? = nil) -> String {
        guard let window = cachedWindow, let directory = cachedDirectoryID,
              cachedDirectoryURL == currentDirectory else { return "geometry=unavailable" }
        let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = local && usesCustomPreview ? (DragMoveIndicator.shared.lastDisplayedCenter ?? previewCenter(local: local)) : previewCenter(local: local)
        let preview = window.convertPoint(fromScreen: point)
        let candidates = cachedTargets.filter { $0.parentID == directory && (!local || $0.id != activeURLID) }
        guard let nearest = candidates.min(by: {
            hypot($0.frame.midX - preview.x, $0.frame.midY - preview.y) < hypot($1.frame.midX - preview.x, $1.frame.midY - preview.y)
        }) else { return "geometry=no-target" }
        func offset(_ point: NSPoint) -> String {
            "\(TabDiagnostics.coordinate(point.x - nearest.frame.midX)),\(TabDiagnostics.coordinate(point.y - nearest.frame.midY))"
        }
        let icon = Self.folderIconHitRect(icon: nearest.iconFrame, tile: nearest.frame)
        let event = eventCursor.map { window.convertPoint(fromScreen: $0) }
        func iconOffset(_ point: NSPoint) -> String {
            "\(TabDiagnostics.coordinate(point.x - icon.midX)),\(TabDiagnostics.coordinate(point.y - icon.midY))"
        }
        return "previewOffset=\(offset(preview)) pointerOffset=\(offset(pointer)) tileSize=\(TabDiagnostics.coordinate(nearest.frame.width))x\(TabDiagnostics.coordinate(nearest.frame.height)) iconSize=\(TabDiagnostics.coordinate(icon.width))x\(TabDiagnostics.coordinate(icon.height)) iconSource=\(nearest.iconFrame == nil ? "fallback" : "view") previewIcon=\(iconOffset(preview)) pointerIcon=\(iconOffset(pointer)) eventIcon=\(event.map(iconOffset) ?? "unavailable")"
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
            var iconFrames: [String: NSRect] = [:]
            var scroll: NSScrollView?
            func collect(_ view: NSView) {
                guard !view.isHidden else { return }
                if let tile = view as? NativeFileTileView, let id = tile.representedID {
                    iconFrames[id] = tile.iconFrameInWindow
                }
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
                        found.append(Target(frame: frame, iconFrame: nil, url: item.url.standardizedFileURL,
                                            id: FileItem.canonicalID(for: item.url),
                                            parentID: item.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path))
                    }
                    return
                }
                for child in view.subviews { collect(child) }
            }
            collect(root)
            cachedTargets = found.map { target in
                var value = target
                value.iconFrame = iconFrames[target.id]
                return value
            }
            cachedScroll = scroll
            cachedBounds = cachedScroll?.contentView.bounds ?? .null
        }
        let point = window.convertPoint(fromScreen: center)
        if cachedDirectoryURL != currentDirectory {
            cachedDirectoryURL = currentDirectory
            cachedDirectoryID = currentDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard let directory = cachedDirectoryID else { return nil }
        var best: Target?
        for target in cachedTargets where target.parentID == directory {
            if excludeSource && target.id == activeURLID { continue }
            // Restrict moves to the actual folder icon, never its filename or
            // the surrounding tile. A fallback is needed while a tile is loading.
            let icon = Self.folderIconHitRect(icon: target.iconFrame, tile: target.frame)
            guard !icon.isNull && icon.contains(point) else { continue }
            if best == nil || target.frame.width * target.frame.height < best!.frame.width * best!.frame.height { best = target }
        }
        return best?.url
    }
}
