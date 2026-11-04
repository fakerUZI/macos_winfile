import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared URL representation for drags from WinFile and other macOS file managers.
enum SidebarFolderDrop {
    private static let localDragType = "local.leaffiles.internal-file-drag"
    private static var draggedURL: URL?
    static var currentDraggedURL: URL? { draggedURL }
    private static var draggedParent: URL?
    private static var checkedDirectory: URL?
    private static var checkedDirectoryMatches = false

    @MainActor static func provider(for url: URL, customPreview: Bool = false, isDirectory: Bool = false) -> NSItemProvider? {
        guard url.isFileURL else { return nil }
        DispatchQueue.main.async { TabDiagnostics.shared.record("sidebar.drag.source") }
        rememberSource(url)
        DragPreviewGeometry.shared.begin(url: url, customPreview: customPreview, isDirectory: isDirectory)
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: localDragType, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    private static func rememberSource(_ url: URL) {
        draggedURL = url
        draggedParent = url.deletingLastPathComponent().standardizedFileURL
        checkedDirectory = nil
    }

    @MainActor static func nativePasteboardItem(for item: FileItem) -> NSPasteboardItem? {
        guard item.url.isFileURL else { return nil }
        let pasteboardItem = NSPasteboardItem()
        guard pasteboardItem.setString(item.url.absoluteString, forType: .fileURL),
              pasteboardItem.setData(Data(), forType: NSPasteboard.PasteboardType(localDragType)) else { return nil }
        rememberSource(item.url)
        DragPreviewGeometry.shared.begin(url: item.url, customPreview: true,
                                         isDirectory: item.isDirectory, managedSession: true)
        return pasteboardItem
    }

    static func operation(for info: DropInfo, currentDirectory: URL?) -> DropOperation {
        guard isLocal(info) else { return .copy }
        return operationForLocalDrag(currentDirectory: currentDirectory)
    }

    static func operationForLocalDrag(currentDirectory: URL?) -> DropOperation {
        guard let directory = currentDirectory, let parent = draggedParent else { return .copy }
        if checkedDirectory != directory {
            checkedDirectory = directory
            checkedDirectoryMatches = parent == directory.standardizedFileURL
                || FileItem.canonicalID(for: parent) == FileItem.canonicalID(for: directory)
        }
        return checkedDirectoryMatches ? .move : .copy
    }

    static func isLocal(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType(exportedAs: localDragType)]) ||
            info.itemProviders(for: [.fileURL]).contains { $0.registeredTypeIdentifiers.contains(localDragType) }
    }

    static func isMovingToFolder(_ info: DropInfo, currentDirectory: URL, destination: URL?) -> Bool {
        guard let destination else { return false }
        return isMovingToFolder(info, currentDirectory: currentDirectory, destination: destination)
    }

    static func isMovingToFolder(_ info: DropInfo, currentDirectory: URL, destination: URL) -> Bool {
        let isMove: Bool
        if case .move = operation(for: info, currentDirectory: currentDirectory) { isMove = true }
        else { isMove = false }
        return isMovingToFolder(source: draggedURL, destination: destination, isMove: isMove)
    }

    static func isMovingToFolder(source: URL?, destination: URL, isMove: Bool) -> Bool {
        guard isMove, let source else { return false }
        return FileItem.canonicalID(for: source) != FileItem.canonicalID(for: destination)
    }

    static func isMovingToFolder(destination: URL?, isMove: Bool) -> Bool {
        guard let destination else { return false }
        return isMovingToFolder(source: draggedURL, destination: destination, isMove: isMove)
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL], Int) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [URL?](repeating: nil, count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                urls[index] = url?.isFileURL == true ? url : nil
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(urls.compactMap { $0 }, urls.filter { $0 == nil }.count)
        }
    }
}

/// A drag from the displayed directory moves into its child; other sources copy.
enum FileDropPolicy {
    enum Action { case move, copy, ignore, mixed }

    static func permittedOperation(preferMove: Bool, allowed: NSDragOperation) -> NSDragOperation {
        let preferred: NSDragOperation = preferMove ? .move : .copy
        if allowed.contains(preferred) { return preferred }
        if allowed.contains(.copy) { return .copy }
        if allowed.contains(.move) { return .move }
        return []
    }

    static func action(for urls: [URL], currentDirectory: URL, destination: URL) -> Action {
        let sources = urls.filter(\.isFileURL)
        guard !sources.isEmpty, currentDirectory.isFileURL, destination.isFileURL else { return .ignore }
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let current = canonical(currentDirectory)
        let target = canonical(destination)
        if sources.contains(where: { canonical($0) == target }) { return .ignore }
        let localCount = sources.filter { canonical($0.deletingLastPathComponent()) == current }.count
        if localCount == sources.count {
            return target == current ? .ignore : .move
        }
        return localCount == 0 ? .copy : .mixed
    }
}

/// A hit-test-transparent in-window preview follows the drag, with scissors
/// shown only when the current target is a move destination.
@MainActor
final class DragMoveIndicator {
    static let shared = DragMoveIndicator()
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private var overlay: NSView?
    var overlayViewForTesting: NSView? { overlay }
    private var cleanupTimer: Timer?
    private var previewView: NSImageView?
    private var scissorsView: NSImageView?
    private var nameView: NSTextField?
    private(set) var hasPreview = false
    private var standaloneIndicator = false
    private var managedBySession = false
    private(set) var lastDisplayedCenter: NSPoint?
    var nativePreviewUpdater: ((Bool) -> Void)?

    func beginPreview(image: NSImage, name: String, managedSession: Bool = false) {
        let view = overlay ?? makeOverlay()
        overlay = view
        hasPreview = true
        standaloneIndicator = false
        managedBySession = managedSession
        lastDisplayedCenter = nil
        if managedSession { return }
        previewView?.image = image
        previewView?.isHidden = false
        nameView?.stringValue = name
        nameView?.isHidden = false
        scissorsView?.isHidden = true
        updatePosition()
        if !managedSession { startTimer() }
    }

    func endPreview() {
        hasPreview = false
        standaloneIndicator = false
        managedBySession = false
        nativePreviewUpdater = nil
        previewView?.image = nil
        previewView?.isHidden = true
        nameView?.stringValue = ""
        nameView?.isHidden = true
        scissorsView?.isHidden = true
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        overlay?.removeFromSuperview()
    }

    func setVisible(_ visible: Bool) {
        if managedBySession {
            nativePreviewUpdater?(visible)
            return
        }
        if hasPreview {
            scissorsView?.isHidden = !visible
            if !managedBySession { updatePosition() }
            return
        }
        guard visible else {
            endPreview()
            return
        }
        if overlay == nil { overlay = makeOverlay() }
        standaloneIndicator = true
        previewView?.isHidden = true
        nameView?.isHidden = true
        scissorsView?.isHidden = false
        updatePosition()
        startTimer()
    }

    private func startTimer() {
        if cleanupTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateForMouseButtons(NSEvent.pressedMouseButtons) }
            }
            cleanupTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
    }

    var diagnosticStatus: String {
        let attached = overlay?.window != nil
        let visible = overlay?.window?.isVisible == true && overlay?.isHiddenOrHasHiddenAncestor == false
        return "preview=\(hasPreview) attached=\(attached) viewVisible=\(visible) scissorsHidden=\(scissorsView?.isHidden ?? true)"
    }

    func updateForMouseButtons(_ buttons: Int) {
        if buttons & 1 == 0 {
            if ProcessInfo.processInfo.environment["WINFILE_DRAG_GEOMETRY"] == "1", hasPreview {
                TabDiagnostics.shared.record("grid.preview.timerEnd", detail: diagnosticStatus)
            }
            endPreview()
            DragPreviewGeometry.shared.restoreSourceIcon()
        } else {
            updatePosition()
        }
    }

    func updatePosition() {
        positionOverlay(screenCenter: DragPreviewGeometry.shared.previewCenter(local: true))
    }

    /// The overlay itself stays fixed over the window; only its pass-through
    /// contents move. Moving the overlay's hit-test bounds during an AppKit
    /// drag can cause the destination to receive a spurious exit.
    func positionOverlay(screenCenter center: NSPoint) {
        if managedBySession {
            lastDisplayedCenter = center
            return
        }
        guard (hasPreview || standaloneIndicator), let view = overlay else { return }
        guard let window = NSApp.orderedWindows.first(where: {
            $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(center) && $0.contentView != nil
        }), let root = window.contentView else {
            view.removeFromSuperview()
            return
        }
        if view.superview !== root {
            view.removeFromSuperview()
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view, positioned: .above, relativeTo: nil)
        } else if view.frame != root.bounds {
            view.frame = root.bounds
        }
        let point = view.convert(window.convertPoint(fromScreen: center), from: nil)
        let iconFrame = NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48)
        let nameFrame = NSRect(x: point.x - 76, y: point.y - 61, width: 152, height: 32)
        let scissorsFrame = NSRect(x: point.x + 12, y: point.y - 28, width: 20, height: 20)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if previewView?.frame != iconFrame { previewView?.frame = iconFrame }
        if nameView?.frame != nameFrame { nameView?.frame = nameFrame }
        if scissorsView?.frame != scissorsFrame { scissorsView?.frame = scissorsFrame }
        CATransaction.commit()
        if hasPreview, let previewView {
            lastDisplayedCenter = Self.screenCenter(of: previewView)
        }
    }

    static func screenCenter(of view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        return window.convertPoint(toScreen: view.convert(center, to: nil))
    }

    private func makeOverlay() -> NSView {
        let content = PassthroughView(frame: NSRect(x: 0, y: 0, width: 160, height: 92))
        content.identifier = NSUserInterfaceItemIdentifier("drag.move.indicator")
        content.wantsLayer = true
        content.layer?.zPosition = 10000
        let preview = NSImageView(frame: NSRect(x: 56, y: 40, width: 48, height: 48))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.isHidden = true
        content.addSubview(preview)
        previewView = preview
        let label = NSTextField(labelWithString: "")
        label.identifier = NSUserInterfaceItemIdentifier("drag.preview.name")
        label.frame = NSRect(x: 4, y: 3, width: 152, height: 32)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.lineBreakMode = .byTruncatingMiddle
        label.isHidden = true
        content.addSubview(label)
        nameView = label
        let imageView = NSImageView(frame: NSRect(x: 92, y: 36, width: 20, height: 20))
        imageView.identifier = NSUserInterfaceItemIdentifier("drag.move.scissors")
        imageView.wantsLayer = true
        imageView.layer?.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        if let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
            let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.saveGState()
                context.translateBy(x: rect.midX, y: rect.midY)
                context.rotate(by: .pi / 2)
                symbol.draw(in: NSRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
                context.restoreGState()
                return true
            }
            image.isTemplate = true
            imageView.image = image
            imageView.contentTintColor = .labelColor
        }
        imageView.isHidden = true
        content.addSubview(imageView)
        scissorsView = imageView
        return content
    }
}

/// Folder targets accept drops before the enclosing view's background target.
struct FileFolderDrop: ViewModifier {
    let item: FileItem
    let model: BrowserModel
    @State private var isLocalMove = false
    @State private var isMoveDestination = false

    @ViewBuilder func body(content: Content) -> some View {
        if item.isDirectory && !item.isBundle && item.url.isFileURL, let current = model.currentDirectory {
            content.onDrop(of: [.fileURL], delegate: FolderTargetDropDelegate(model: model, current: current,
                destination: item.url, isLocalMove: $isLocalMove, isMoveDestination: $isMoveDestination))
        } else { content }
    }
}

struct FolderTargetDropDelegate: DropDelegate {
    let model: BrowserModel
    let current: URL
    let destination: URL
    @Binding var isLocalMove: Bool
    @Binding var isMoveDestination: Bool

    func dropEntered(info: DropInfo) {
        let operation = SidebarFolderDrop.operation(for: info, currentDirectory: current)
        let moving: Bool
        if case .move = operation { moving = true } else { moving = false }
        if isLocalMove != moving { isLocalMove = moving }
        let show = SidebarFolderDrop.isMovingToFolder(info, currentDirectory: current, destination: destination)
        if isMoveDestination != show { isMoveDestination = show }
        DragMoveIndicator.shared.setVisible(show)
    }
    func dropExited(info: DropInfo) {
        DragMoveIndicator.shared.setVisible(false)
        if isMoveDestination { isMoveDestination = false }
        if isLocalMove { isLocalMove = false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isMoveDestination { DragMoveIndicator.shared.updatePosition() }
        return DropProposal(operation: isLocalMove ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        DragPreviewGeometry.shared.restoreSourceIcon()
        if isMoveDestination { isMoveDestination = false }
        if isLocalMove { isLocalMove = false }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        SidebarFolderDrop.load(providers) { urls, failed in
            model.dropFiles(urls, from: current, to: destination, failed: failed)
        }
        return true
    }
}

struct FileListDropDelegate: DropDelegate {
    let model: BrowserModel

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: SidebarFolderDrop.operation(for: info, currentDirectory: model.currentDirectory))
    }
    func performDrop(info: DropInfo) -> Bool {
        guard let directory = model.currentDirectory else {
            DragPreviewGeometry.shared.restoreSourceIcon()
            return false
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else {
            DragPreviewGeometry.shared.restoreSourceIcon()
            return false
        }
        DragPreviewGeometry.shared.restoreSourceIcon()
        SidebarFolderDrop.load(providers) { urls, failed in
            model.dropFiles(urls, from: directory, to: directory, failed: failed)
        }
        return true
    }
}

struct SidebarFolderDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onFolders: ([URL], Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) {
        isTargeted = true
        DispatchQueue.main.async { TabDiagnostics.shared.record("sidebar.drop.entered") }
    }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        DragPreviewGeometry.shared.restoreSourceIcon()
        DispatchQueue.main.async { TabDiagnostics.shared.record("sidebar.drop.performed") }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        SidebarFolderDrop.load(providers, completion: onFolders)
        return true
    }
}
