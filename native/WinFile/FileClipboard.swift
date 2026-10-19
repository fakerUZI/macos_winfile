import AppKit
import Combine

/// A single clipboard for all windows/tabs. Pasteboard generations invalidate old cuts.
@MainActor
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard(pasteboard: .general)
    @Published private(set) var revision = 0
    let pasteboard: NSPasteboard
    private var local: ClipboardPayload?
    private var android: BrowserModel.AndroidClipboardPayload?
    private var observedChangeCount: Int
    private var timer: Timer?

    init(pasteboard: NSPasteboard, monitor: Bool = true) {
        self.pasteboard = pasteboard
        observedChangeCount = pasteboard.changeCount
        if monitor {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }
    deinit { timer?.invalidate() }
    var changeCount: Int { pasteboard.changeCount }
    var localPayload: ClipboardPayload? {
        if pasteboard.changeCount == observedChangeCount, let local { return local }
        // Files copied in Finder or another app are always copies; only our own generation can be a cut.
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.isEmpty ? nil : ClipboardPayload(mode: .copy, urls: urls)
    }
    var androidPayload: BrowserModel.AndroidClipboardPayload? {
        pasteboard.changeCount == observedChangeCount ? android : nil
    }
    func refresh() {
        guard pasteboard.changeCount != observedChangeCount else { return }
        observedChangeCount = pasteboard.changeCount
        local = nil
        android = nil
        revision += 1
    }
    func write(_ payload: ClipboardPayload) {
        pasteboard.clearContents()
        pasteboard.writeObjects(payload.urls as [NSURL])
        observedChangeCount = pasteboard.changeCount
        local = payload
        android = nil
        revision += 1
    }
    func writeAndroid(_ payload: BrowserModel.AndroidClipboardPayload) {
        pasteboard.clearContents()
        observedChangeCount = pasteboard.changeCount
        local = nil
        android = payload
        revision += 1
    }
    func clear(ifGeneration generation: Int) {
        guard pasteboard.changeCount == generation else { return }
        pasteboard.clearContents()
        observedChangeCount = pasteboard.changeCount
        local = nil
        android = nil
        revision += 1
    }
}
