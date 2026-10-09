// 查询「该文件会用哪个应用打开」，并缓存应用图标
//
// 用途：在文件图标右下角显示关联应用的徽标。
// 性能考虑：NSWorkspace 查询有系统开销，按扩展名缓存结果；
// 图标本身也缓存，避免每个磁贴重复取图。
import AppKit
import Combine

@MainActor
final class DefaultAppService: ObservableObject {

    static let shared = DefaultAppService()

    /// 是否显示关联应用徽标（用户可在设置中关闭）
    @Published var showsBadges: Bool {
        didSet { UserDefaults.standard.set(showsBadges, forKey: Self.badgesKey) }
    }

    private static let badgesKey = "ShowsDefaultAppBadge"

    /// 扩展名 → 应用路径（nil 表示查询过但无结果）
    private var appCache: [String: String?] = [:]
    /// 应用路径 → 图标
    private var iconCache: [String: NSImage] = [:]

    private init() {
        // 默认开启
        if UserDefaults.standard.object(forKey: Self.badgesKey) == nil {
            showsBadges = true
        } else {
            showsBadges = UserDefaults.standard.bool(forKey: Self.badgesKey)
        }
    }

    /// 该文件会用哪个应用打开。
    /// 顺序：WinFile 内自定义设置 → 系统默认。
    func defaultApplication(for url: URL) -> URL? {
        guard let ext = FileAssociations.key(for: url) else { return nil }
        if let cached = appCache[ext] { return cached.map { URL(fileURLWithPath: $0) } }

        var resolved: URL?
        if let custom = FileAssociations.shared.application(forExtension: ext) {
            resolved = custom
        } else {
            resolved = NSWorkspace.shared.urlForApplication(toOpen: url)
        }
        appCache[ext] = resolved?.path
        return resolved
    }

    /// 关联应用的图标
    func badgeIcon(for url: URL, size: CGFloat) -> NSImage? {
        guard showsBadges, let app = defaultApplication(for: url) else { return nil }
        let key = "\(app.path)|\(Int(size))"
        if let cached = iconCache[key] { return cached }

        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: size, height: size)
        iconCache[key] = icon
        if iconCache.count > 400 { iconCache.removeAll(keepingCapacity: true) }
        return icon
    }

    /// 设置变更后失效缓存，并通知界面刷新。
    ///
    /// 必须触发 objectWillChange：文件图标视图观察本对象，
    /// 若只清缓存不发通知，界面上的徽标要等到下次重建才更新
    /// （表现为"改了打开方式，切换文件夹后才生效"）。
    func invalidate() {
        appCache.removeAll()
        iconCache.removeAll()
        objectWillChange.send()
    }
}
