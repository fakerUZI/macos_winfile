import AppKit
import Combine

/// Native hosting views have independent SwiftUI focus scopes. Resolve menu
/// commands through the actual key window, including when focus is in a cached
/// table, and forward selection changes so menu validation stays current.
@MainActor
final class BrowserWindowCommands: ObservableObject {
    static let shared = BrowserWindowCommands()
    private let managers = NSMapTable<NSWindow, TabManager>.weakToWeakObjects()
    private var detachedManagers: [UUID: TabManager] = [:]
    var openNewWindow: (() -> Void)?
    private weak var observedManager: TabManager?
    private var modelSubscription: AnyCancellable?
    private var notifications = Set<AnyCancellable>()

    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] note in
                    if name == NSWindow.willCloseNotification, let window = note.object as? NSWindow {
                        if let manager = self?.managers.object(forKey: window) {
                            self?.detachedManagers = self?.detachedManagers.filter { $0.value !== manager } ?? [:]
                        }
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

    /// Only real windows and a pending detached window participate in session saving.
    /// SwiftUI may construct temporary MainView values that never become a window.
    func sessionManagers(including candidate: TabManager) -> [TabManager] {
        var result: [TabManager] = []
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows {
            if let manager = managers.object(forKey: window), seen.insert(ObjectIdentifier(manager)).inserted {
                result.append(manager)
            }
        }
        for manager in detachedManagers.values where seen.insert(ObjectIdentifier(manager)).inserted {
            result.append(manager)
        }
        if WindowBridge.shared.tabManager === candidate, seen.insert(ObjectIdentifier(candidate)).inserted {
            result.append(candidate)
        }
        return result
    }

    func register(_ manager: TabManager, for window: NSWindow) {
        guard managers.object(forKey: window) !== manager else { return }
        managers.setObject(manager, forKey: window)
        ExternalFileRequests.shared.register(manager, window: window)
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func prepareDetachedWindow(from source: TabManager, tab: WinFileTab, engine: FSEngine) -> UUID? {
        guard source.count > 1 else { return nil }
        let destination = TabManager(engine: engine, startDirectory: nil, persistSession: true)
        guard source.transfer(tab, to: destination, replacePlaceholder: true) else { return nil }
        let id = UUID()
        detachedManagers[id] = destination
        return id
    }

    /// A new window starts with its own tab instead of restoring the existing session again.
    func prepareNewWindow(engine: FSEngine, startDirectory: URL?) -> UUID {
        let id = UUID()
        detachedManagers[id] = TabManager(engine: engine, startDirectory: startDirectory, persistSession: true)
        return id
    }

    func detachedManager(for id: UUID?) -> TabManager? {
        guard let id else { return nil }
        return detachedManagers[id]
    }

    func mergeOtherWindows(into destination: TabManager) {
        let windows = NSApp.windows.filter { window in
            guard let manager = managers.object(forKey: window) else { return false }
            return manager !== destination
        }
        for window in windows {
            guard let manager = managers.object(forKey: window) else { continue }
            manager.mergeAll(into: destination)
            window.close()
        }
    }

    var hasOtherWindows: Bool {
        guard let current = manager else { return false }
        return NSApp.windows.contains { window in
            guard let other = managers.object(forKey: window) else { return false }
            return other !== current
        }
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
