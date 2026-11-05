import AppKit
import SwiftUI

/// Only the active host participates in the native view hierarchy. Keep up to
/// three recently used hosts so switching back preserves tables and scroll state
/// without retaining a heavy view for every open tab.
struct CachedTabContent: NSViewRepresentable {
    let engine: FSEngine
    let manager: TabManager
    let tab: WinFileTab
    let tabs: [WinFileTab]
    @Binding var dialog: DialogKind?
    let openFolderPanel: () -> Void
    var onActivate: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TabContentContainerView { TabContentContainerView() }
    func updateNSView(_ view: TabContentContainerView, context: Context) {
        context.coordinator.activate(self, in: view)
    }

    @MainActor
    final class Coordinator {
        static let capacity = 3
        private var hosts: [UUID: NSHostingView<AnyView>] = [:]
        private var recency: [UUID] = []
        private var activeID: UUID?
        private var language = ""
        private var pressureObserver: NSObjectProtocol?
        init() {
            pressureObserver = NotificationCenter.default.addObserver(forName: .winFileMemoryPressure, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for id in Array(self.hosts.keys) where id != self.activeID { self.hosts.removeValue(forKey: id) }
                    self.recency = self.recency.filter { $0 == self.activeID }
                }
            }
        }
        deinit { if let pressureObserver { NotificationCenter.default.removeObserver(pressureObserver) } }

        private func content(_ input: CachedTabContent, model: BrowserModel) -> AnyView {
            AnyView(TabContentHost(engine: input.engine, model: model, dialog: input.$dialog,
                                  openFolderPanel: input.openFolderPanel)
                .environment(\.locale, Localization.shared.locale))
        }

        func activate(_ input: CachedTabContent, in container: TabContentContainerView) {
            container.manager = input.manager
            container.onActivate = input.onActivate
            if let window = container.window { BrowserWindowCommands.shared.register(input.manager, for: window) }
            let live = Set(input.tabs.map(\.id))
            for id in Array(hosts.keys) where !live.contains(id) {
                hosts.removeValue(forKey: id)?.removeFromSuperview()
            }
            recency.removeAll { !live.contains($0) }
            let nextLanguage = Localization.languageCode
            if language != nextLanguage {
                language = nextLanguage
                for tab in input.tabs {
                    if let host = hosts[tab.id] { host.rootView = content(input, model: tab.model) }
                }
            }
            let id = input.tab.id
            let host: NSHostingView<AnyView>
            if let cached = hosts[id] { host = cached }
            else {
                host = NSHostingView(rootView: content(input, model: input.tab.model))
                host.sizingOptions = []
                host.autoresizingMask = [.width, .height]
                hosts[id] = host
            }
            if activeID != id || host.superview !== container {
                container.subviews.forEach { $0.removeFromSuperview() }
                host.frame = container.bounds
                container.addSubview(host)
                activeID = id
                recency.removeAll { $0 == id }; recency.append(id)
                input.tab.model.beginWatchingDirectory()
                WindowBridge.shared.recordContentKind(TabContentHost.renderedKind(for: input.tab.model))
            }
            while recency.count > Self.capacity {
                let evicted = recency.removeFirst()
                hosts.removeValue(forKey: evicted)?.removeFromSuperview()
            }
            container.retainedHostCount = hosts.count
        }
    }
}

final class TabContentContainerView: NSView {
    var retainedHostCount = 0
    weak var manager: TabManager?
    var onActivate: (() -> Void)?
    private var mouseMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let window, let manager { BrowserWindowCommands.shared.register(manager, for: window) }
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            self.onActivate?()
            return event
        }
    }
    deinit { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }
}
