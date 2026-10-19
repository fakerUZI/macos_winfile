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
                guard let self, event.window === self.window, let model = self.model else { return event }
                if event.window?.firstResponder is NSTextView || event.window?.firstResponder is NSTextField { return event }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
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
