import AppKit

/// One entry point for Launch Services and Finder Services. Requests arriving
/// during a cold launch wait for a real browser window, preserving restored tabs.
@MainActor
final class ExternalFileRequests: NSObject {
    static let shared = ExternalFileRequests()
    enum Intent { case open, reveal }
    private var pending: [(urls: [URL], intent: Intent)] = []
    private weak var browserWindow: NSWindow?
    private weak var manager: TabManager?

    func receive(_ urls: [URL], intent: Intent) {
        var seen = Set<String>()
        let files = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        guard !files.isEmpty else { return }
        pending.append((files, intent))
        drain()
    }

    func register(_ manager: TabManager, window: NSWindow) {
        self.manager = manager
        browserWindow = window
        drain()
    }

    private func drain() {
        guard !pending.isEmpty, let manager = BrowserWindowCommands.shared.manager ?? manager,
              let window = (NSApp.keyWindow.flatMap { BrowserWindowCommands.shared.manager(for: $0) === manager ? $0 : nil }) ?? browserWindow else { return }
        let requests = pending
        pending.removeAll()
        for request in requests {
            Self.apply(request.urls, intent: request.intent, to: manager)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Never passes an incoming file back to its default app: LeafFiles itself
    /// may be that app, which would otherwise cause an Apple-event loop.
    static func apply(_ urls: [URL], intent: Intent, to manager: TabManager) {
        for url in urls where url.isFileURL {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    manager.newTab(startDirectory: url)
                } else {
                    let tab = manager.newTab(startDirectory: url.deletingLastPathComponent())
                    tab.model.pendingSelectionID = FileItem.canonicalID(for: url)
                    if intent == .open, ArchiveService.isArchive(url) {
                        tab.model.previewArchive(url)
                    }
                }
            } catch {
                manager.activeModel.errorMessage = error.localizedDescription
                TabDiagnostics.shared.recordFileError(error, operation: "externalOpen", url: url)
            }
        }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.filter(\.isFileURL) }
        // Older file providers still send the filenames property-list flavor.
        let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }

    @objc(showInLeafFiles:userData:error:)
    func showInLeafFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = L("external.noFiles", "未收到可定位的本地文件或文件夹。") as NSString
            return
        }
        receive(urls, intent: .reveal)
    }
}
