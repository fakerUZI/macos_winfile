import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared URL representation for drags from WinFile and other macOS file managers.
enum SidebarFolderDrop {
    static func provider(for url: URL) -> NSItemProvider? {
        guard url.isFileURL else { return nil }
        DispatchQueue.main.async { TabDiagnostics.shared.record("sidebar.drag.source") }
        return NSItemProvider(object: url as NSURL)
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
