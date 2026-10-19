import AppKit
import Quartz

@MainActor
final class QuickLookService: NSResponder, QLPreviewPanelDataSource {
    static let shared = QuickLookService()
    private var urls: [URL] = []
    private weak var hostWindow: NSWindow?
    func show(_ urls: [URL]) {
        self.urls = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !self.urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        guard let window = (NSApp.keyWindow is QLPreviewPanel ? NSApp.mainWindow : NSApp.keyWindow) else { return }
        if hostWindow !== window {
            if let old = hostWindow, old.nextResponder === self { old.nextResponder = nextResponder }
            nextResponder = window.nextResponder
            window.nextResponder = self
            hostWindow = window
        }
        panel.updateController()
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !urls.isEmpty && hostWindow != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
