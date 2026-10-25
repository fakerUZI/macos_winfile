import AppKit
import Combine

/// Native hosting views have independent SwiftUI focus scopes. Resolve menu
/// commands through the actual key window, including when focus is in a cached
/// table, and forward selection changes so menu validation stays current.
@MainActor
final class BrowserWindowCommands: ObservableObject {
    static let shared = BrowserWindowCommands()
    private let managers = NSMapTable<NSWindow, TabManager>.weakToWeakObjects()
    private weak var observedManager: TabManager?
    private var modelSubscription: AnyCancellable?
    private var notifications = Set<AnyCancellable>()

    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] note in
                    if name == NSWindow.willCloseNotification, let window = note.object as? NSWindow {
                        self?.managers.removeObject(forKey: window)
                    }
                    DispatchQueue.main.async { self?.refresh() }
                }
                .store(in: &notifications)
        }
    }

    var manager: TabManager? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return manager(for: window)
    }

    func manager(for window: NSWindow) -> TabManager? { managers.object(forKey: window) }

    func register(_ manager: TabManager, for window: NSWindow) {
        guard managers.object(forKey: window) !== manager else { return }
        managers.setObject(manager, forKey: window)
        ExternalFileRequests.shared.register(manager, window: window)
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let next = manager
        guard observedManager !== next else { return }
        observedManager = next
        modelSubscription = next?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        objectWillChange.send()
    }
}
