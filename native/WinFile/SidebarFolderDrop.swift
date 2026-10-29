import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared URL representation for drags from WinFile and other macOS file managers.
enum SidebarFolderDrop {
    private static let localDragType = "local.leaffiles.internal-file-drag"
    private static var draggedURL: URL?

    static func provider(for url: URL) -> NSItemProvider? {
        guard url.isFileURL else { return nil }
        DispatchQueue.main.async { TabDiagnostics.shared.record("sidebar.drag.source") }
        draggedURL = url
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: localDragType, visibility: .ownProcess) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    static func operation(for info: DropInfo, currentDirectory: URL?) -> DropOperation {
        guard let directory = currentDirectory, let url = draggedURL,
              info.itemProviders(for: [.fileURL]).contains(where: { $0.registeredTypeIdentifiers.contains(localDragType) }),
              FileItem.canonicalID(for: url.deletingLastPathComponent()) == FileItem.canonicalID(for: directory) else {
            return .copy
        }
        return .move
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
        let localCount = sources.filter { canonical($0.deletingLastPathComponent()) == current }.count
        if localCount == sources.count {
            return canonical(destination) == current ? .ignore : .move
        }
        return localCount == 0 ? .copy : .mixed
    }
}

/// Folder targets accept drops before the enclosing view's background target.
struct FileFolderDrop: ViewModifier {
    let item: FileItem
    let model: BrowserModel

    @ViewBuilder func body(content: Content) -> some View {
        if item.isDirectory && !item.isBundle && item.url.isFileURL, let current = model.currentDirectory {
            content.onDrop(of: [.fileURL], delegate: FolderTargetDropDelegate(model: model, current: current, destination: item.url))
        } else { content }
    }
}

struct FolderTargetDropDelegate: DropDelegate {
    let model: BrowserModel
    let current: URL
    let destination: URL

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: SidebarFolderDrop.operation(for: info, currentDirectory: current))
    }
    func performDrop(info: DropInfo) -> Bool {
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
        guard let directory = model.currentDirectory else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
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
        DispatchQueue.main.async { TabDiagnostics.shared.record("sidebar.drop.performed") }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        SidebarFolderDrop.load(providers, completion: onFolders)
        return true
    }
}

struct LocalFileDrag: ViewModifier {
    let url: URL
    @ViewBuilder func body(content: Content) -> some View {
        if url.isFileURL { content.onDrag { SidebarFolderDrop.provider(for: url) ?? NSItemProvider() } }
        else { content }
    }
}
