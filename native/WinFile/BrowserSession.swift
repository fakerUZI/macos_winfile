import Foundation

struct SavedBrowserTab: Codable {
    var kind: String
    var path: String?
    var category: String?
    var sort: String
    var ascending: Bool
    var layout: String
    var query: String
    var hidden: Bool?
    var pinned: Bool?
    var wechat: WeChatFilterState?
    var software: String?
    var cleanupSection: CleanupSection?
    var criteria: FileSearchCriteria?

    @MainActor init(model: BrowserModel) {
        sort = model.sortField.rawValue
        ascending = model.sortAscendingFlag
        layout = model.layout.rawValue
        query = model.isSearching ? model.searchQuery : ""
        hidden = model.showHidden
        wechat = model.isWeChatCleanupView ? model.weChatCleanup.filterState : nil
        software = model.isWeChatCleanupView ? model.softwareCleanup.selectedSoftwareID : nil
        cleanupSection = model.isCleanupView ? model.cleanupSection : nil
        criteria = model.isSearching ? model.searchCriteria : nil
        switch model.selection {
        case .folder(let url) where url.isFileURL: kind = "folder"; path = url.path
        case .category(let value): kind = "category"; category = value.rawValue
        case .thisPC: kind = "thisPC"
        case .applications: kind = "applications"
        case .appData: kind = "appData"
        case .weChatCleanup, .storageCleanup: kind = "storageCleanup"
        case .photoLibrary: kind = "photoLibrary"
        default: kind = "home"
        }
    }

    @MainActor func apply(to model: BrowserModel) {
        model.showHidden = hidden ?? model.showHidden
        model.sortField = SortField(rawValue: sort) ?? .name
        model.sortAscendingFlag = ascending
        model.layout = ViewLayout(rawValue: layout) ?? .details
        let softwareID = software ?? "wechat"
        model.selectCleanupSoftware(model.softwareCleanup.softwareChoices.contains { $0.id == softwareID } ? softwareID : "wechat")
        model.weChatCleanup.restoreFilters(wechat)
        model.searchCriteria = criteria ?? FileSearchCriteria()
        model.navigate(to: destination)
        if kind == "folder", model.currentDirectory != nil, !query.isEmpty || model.searchCriteria.isActive {
            model.search(query)
        }
    }
    var destination: SidebarSelection {
        switch kind {
        case "folder":
            guard let path else { return .home }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return .home }
            return .folder(URL(fileURLWithPath: path))
        case "category": return FileCategory(rawValue: category ?? "").map { .category($0) } ?? .home
        case "thisPC": return .thisPC
        case "applications": return .applications
        case "appData": return .appData
        case "wechat": return .weChatCleanup
        case "storageCleanup": return cleanupSection == .software ? .weChatCleanup : .storageCleanup
        case "photoLibrary": return .photoLibrary
        default: return .home
        }
    }
}

struct SavedBrowserSession: Codable {
    var version = 1
    var tabs: [SavedBrowserTab]
    var activeIndex: Int
}

@MainActor
final class BrowserSessionStore {
    static let shared = BrowserSessionStore(defaults: .standard)
    static let key = "BrowserSession.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func load() -> SavedBrowserSession? {
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(SavedBrowserSession.self, from: data),
              saved.version == 1, !saved.tabs.isEmpty, saved.tabs.count <= 30 else { return nil }
        return saved
    }
    func save(tabs: [WinFileTab], activeID: UUID?) {
        var kept = Array(tabs.prefix(30))
        if let active = tabs.first(where: { $0.id == activeID }), !kept.contains(where: { $0.id == activeID }), !kept.isEmpty {
            kept[kept.count - 1] = active
        }
        let saved = SavedBrowserSession(tabs: kept.map { tab in
            var saved = SavedBrowserTab(model: tab.model); saved.pinned = tab.isPinned; return saved
        },
                                       activeIndex: kept.firstIndex { $0.id == activeID } ?? 0)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
