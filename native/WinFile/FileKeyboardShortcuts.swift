import AppKit
import SwiftUI

/// Local monitor is scoped to this content window and leaves text editing to AppKit.
struct FileKeyboardShortcuts: NSViewRepresentable {
    let model: BrowserModel
    func makeNSView(context: Context) -> Installer { Installer() }
    func updateNSView(_ view: Installer, context: Context) { view.model = model }
    final class Installer: NSView {
        weak var model: BrowserModel?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window === NSApp.keyWindow, window.attachedSheet == nil,
                      let model = self.model,
                      BrowserWindowCommands.shared.manager(for: window)?.activeModel === model else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let isSelectAll = modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "a"
                if let editor = window.firstResponder as? NSTextView {
                    if isSelectAll { editor.selectAll(nil); return nil }
                    return event
                }
                if window.firstResponder is NSTextField { return event }
                guard model.showsFileList || model.isCleanupView || model.isAndroidPath else { return event }
                if isSelectAll {
                    model.selectAll()
                    return nil
                }
                if event.keyCode == 125, modifiers == .command, !model.selectedItems.isEmpty {
                    for item in model.selectedItems { model.activate(item) }
                    return nil
                }
                if event.keyCode == 51, modifiers == .command, !model.selectedIDs.isEmpty {
                    NotificationCenter.default.post(name: .winFileDeleteSelection, object: model.tabManager)
                    return nil
                }
                if event.keyCode == 49, modifiers.isEmpty, !model.selectedIDs.isEmpty {
                    model.previewSelection()
                    return nil
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
