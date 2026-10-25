import AppKit

/// SwiftUI's locale updates our commands, but AppKit's generated menu titles
/// retain the launch language. Translate those items without replacing targets,
/// actions, shortcuts or the Services menu supplied by macOS.
@MainActor
final class NativeMenuLocalization {
    static let shared = NativeMenuLocalization()
    private var observers: [NSObjectProtocol] = []
    private var titleObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var scheduled = false
    private var applying = false

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.leafLanguageChanged, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        // SwiftUI materializes native menu items lazily while tracking. A queued
        // main-dispatch update runs only after that tracking loop has ended, so
        // update the actual changed menu synchronously (guarding our own edits).
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.refresh(changedMenu: note.object as? NSMenu) }
            })
        }
        schedule()
    }

    private func schedule() {
        guard !applying, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.refresh()
        }
    }

    func refresh(changedMenu: NSMenu? = nil) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        // SwiftUI also resets submenu.title without changing any menu items
        // (notably Help). AppKit uses that title in the menu bar. Observe only
        // the current top-level menus and release replaced menus immediately.
        if let root = NSApp.mainMenu {
            let submenus = root.items.compactMap(\.submenu)
            let live = Set(submenus.map(ObjectIdentifier.init))
            titleObservers = titleObservers.filter { live.contains($0.key) }
            for submenu in submenus where titleObservers[ObjectIdentifier(submenu)] == nil {
                titleObservers[ObjectIdentifier(submenu)] = submenu.observe(\.title) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        if let changedMenu {
            let isApplicationMenu = changedMenu === NSApp.mainMenu?.items.first?.submenu
                || changedMenu.items.contains { $0.action == #selector(NSApplication.terminate(_:)) }
            if changedMenu === NSApp.servicesMenu { Self.translateServices(changedMenu) }
            else { Self.translate(changedMenu, topLevel: changedMenu === NSApp.mainMenu, applicationMenu: isApplicationMenu) }
        } else {
            if let menu = NSApp.mainMenu { Self.translate(menu, topLevel: true) }
            for window in NSApp.windows where ["Settings", "设置", "Preferences", "偏好设置"].contains(window.title) {
                window.title = L("nativeMenu.settingsTitle", "设置")
            }
        }
    }

    static func translate(_ menu: NSMenu, topLevel: Bool = false, applicationMenu: Bool = false) {
        if applicationMenu {
            // Some SwiftUI versions append their Settings-scene command after
            // our localized SettingsLink even when appSettings is replaced.
            // Keep our first command and hide the duplicate without changing its
            // private target or removing items owned by SwiftUI.
            let settings = menu.items.filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
            for duplicate in settings.dropFirst() where !duplicate.isHidden { duplicate.isHidden = true }
        }
        let headings = ["File": "file", "文件": "file", "Edit": "edit", "编辑": "edit",
                        "View": "view", "显示": "view", "Window": "window", "窗口": "window",
                        "Help": "help", "帮助": "help"]
        let actions = ["orderFrontStandardAboutPanel:": "about", "showSettingsWindow:": "settings",
                       "showPreferencesWindow:": "settings", "hide:": "hide",
                       "hideOtherApplications:": "hideOthers", "unhideAllApplications:": "showAll",
                       "terminate:": "quit", "performMiniaturize:": "minimize",
                       "performZoom:": "zoom", "arrangeInFront:": "bringAllToFront",
                       "selectAll:": "selectAll", "undo:": "undo", "redo:": "redo",
                       "performClose:": "close", "closeAll:": "closeAll", "cut:": "cut",
                       "copy:": "copy", "paste:": "paste", "delete:": "delete",
                       "startDictation:": "dictation", "orderFrontCharacterPalette:": "emoji"]
        for (index, item) in menu.items.enumerated() {
            var key = item.action.flatMap { actions[NSStringFromSelector($0)] }
            if topLevel, let heading = headings[item.title] { key = heading }
            if item.submenu != nil, ["AutoFill", "自动填充"].contains(item.title),
               menu.items.contains(where: { $0.action == Selector(("startDictation:")) }) { key = "autofill" }
            // SwiftUI's Settings item uses a private generic menuAction: target;
            // identify its standard shortcut within the application menu instead.
            if applicationMenu, item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command { key = "settings" }
            if applicationMenu, ["退出并保留窗口", "Quit and Keep Windows"].contains(item.title) { key = "quitKeepWindows" }
            if let submenu = item.submenu, let services = NSApp?.servicesMenu, submenu === services { key = "services" }
            if item.action == #selector(NSWindow.toggleFullScreen(_:)) {
                key = NSApp?.keyWindow?.styleMask.contains(.fullScreen) == true ? "exitFullScreen" : "enterFullScreen"
            }
            if let key {
                let title = L("nativeMenu.\(key)", item.title)
                if item.title != title { item.title = title }
                // AppKit draws the submenu's title in the menu bar.
                if topLevel, let submenu = item.submenu, submenu.title != title { submenu.title = title }
            }
            // Third-party Services entries are owned/localized by their providers.
            if let submenu = item.submenu {
                if submenu === NSApp?.servicesMenu { translateServices(submenu) }
                else { translate(submenu, applicationMenu: topLevel && index == 0) }
            }
        }
    }

    private static func translateServices(_ menu: NSMenu) {
        let nativeItems = ["Services Settings…": "servicesSettings", "Services Preferences…": "servicesSettings",
                           "服务设置…": "servicesSettings", "服务偏好设置…": "servicesSettings",
                           "No Services Apply": "noServices", "没有服务可应用": "noServices"]
        for item in menu.items {
            if let key = nativeItems[item.title] {
                let title = L("nativeMenu.\(key)", item.title)
                if item.title != title { item.title = title }
            }
        }
    }
}

extension Notification.Name {
    static let leafLanguageChanged = Notification.Name("LeafFilesLanguageChanged")
}
