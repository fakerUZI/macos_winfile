import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared URL representation for drags from WinFile and other macOS file managers.
enum SidebarFolderDrop {
    private static let localDragType = "local.leaffiles.internal-file-drag"
    private static var draggedURL: URL?
    private static var draggedParent: URL?
    private static var checkedDirectory: URL?
    private static var checkedDirectoryMatches = false

    @MainActor static func provider(for url: URL, customPreview: Bool = false, isDirectory: Bool = false) -> NSItemProvider? {
        guard url.isFileURL else { return nil }
        DispatchQueue.main.async { TabDiagnostics.shared.record("sidebar.drag.source") }
        DragPreviewGeometry.shared.begin(url: url, customPreview: customPreview, isDirectory: isDirectory)
        draggedURL = url
        draggedParent = url.deletingLastPathComponent().standardizedFileURL
        checkedDirectory = nil
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: localDragType, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    static func operation(for info: DropInfo, currentDirectory: URL?) -> DropOperation {
        guard let directory = currentDirectory, let parent = draggedParent,
              isLocal(info) else {
            return .copy
        }
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

/// A transparent, mouse-ignoring badge follows the drag image without changing
/// the drag source or the folder's hit testing. It exists only over a move target.
@MainActor
final class DragMoveIndicator {
    static let shared = DragMoveIndicator()
    private var panel: NSPanel?
    private var cleanupTimer: Timer?
    private var previewView: NSImageView?
    private var scissorsView: NSImageView?
    private(set) var hasPreview = false
    private var pendingOrigin: NSPoint?

    /// SwiftUI's system preview is transparent; this owned image can disappear
    /// immediately on release, without waiting for the system's drop animation.
    func beginPreview(image: NSImage) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        hasPreview = true
        TabDiagnostics.shared.record("grid.drag.preview", detail: "visible=true")
        previewView?.image = image
        previewView?.isHidden = false
        scissorsView?.isHidden = true
        updatePosition()
        if !panel.isVisible { panel.orderFrontRegardless() }
        startTimer()
    }

    func endPreview() {
        if hasPreview { TabDiagnostics.shared.record("grid.drag.preview", detail: "visible=false") }
        hasPreview = false
        previewView?.image = nil
        previewView?.isHidden = true
        scissorsView?.isHidden = true
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        pendingOrigin = nil
        panel?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if hasPreview {
            scissorsView?.isHidden = !visible
            if visible { updatePosition() }
            return
        }
        guard visible else {
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            pendingOrigin = nil
            scissorsView?.isHidden = true
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        previewView?.isHidden = true
        scissorsView?.isHidden = false
        updatePosition()
        if !panel.isVisible { panel.orderFrontRegardless() }
        startTimer()
    }

    private func startTimer() {
        if cleanupTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateForMouseButtons(NSEvent.pressedMouseButtons)
                }
            }
            cleanupTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
    }

    func updateForMouseButtons(_ buttons: Int) {
        if buttons & 1 == 0 {
            endPreview()
            DragPreviewGeometry.shared.restoreSourceIcon()
        } else {
            updatePosition()
            flushPosition()
        }
    }

    func updatePosition() {
        guard let panel else { return }
        let center = DragPreviewGeometry.shared.previewCenter(local: true)
        let origin = NSPoint(x: center.x - 24, y: center.y - 28)
        if !panel.isVisible {
            pendingOrigin = nil
            if panel.frame.origin != origin { move(panel, to: origin) }
            return
        }
        pendingOrigin = origin
    }

    private func flushPosition() {
        guard let panel, panel.isVisible, let origin = pendingOrigin else { return }
        pendingOrigin = nil
        if panel.frame.origin != origin { move(panel, to: origin) }
    }

    private func move(_ panel: NSPanel, to origin: NSPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrameOrigin(origin)
        CATransaction.commit()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.identifier = NSUserInterfaceItemIdentifier("drag.move.indicator")
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let preview = NSImageView(frame: NSRect(x: 0, y: 4, width: 48, height: 48))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.isHidden = true
        content.addSubview(preview)
        previewView = preview
        let imageView = NSImageView(frame: NSRect(x: 36, y: 0, width: 20, height: 20))
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
        panel.contentView = content
        return panel
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

struct LocalFileDrag: ViewModifier {
    let url: URL
    let isDirectory: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if url.isFileURL {
            content.onDrag {
                SidebarFolderDrop.provider(for: url, customPreview: true, isDirectory: isDirectory) ?? NSItemProvider()
            } preview: { Color.black.opacity(0.004).frame(width: 48, height: 48) }
        }
        else { content }
    }
}
