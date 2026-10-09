// WinFile 内部的默认打开方式
//
// 需求：在 WinFile 里为某类文件指定默认应用，但**不影响 macOS 本身**。
// 因此这里的数据只存在本应用的 UserDefaults 里，绝不调用
// NSWorkspace.setDefaultApplication(_:toOpen:) 之类的系统级 API ——
// 系统「始终以此方式打开」的设置完全不受影响，访达与其它应用仍按原样打开。
import AppKit
import Combine
import Foundation

@MainActor
final class FileAssociations: ObservableObject {

    static let shared = FileAssociations()

    /// 键为小写扩展名（如 pdf），值为应用路径
    @Published private(set) var map: [String: String]

    private let key = "WinFileDefaultApplications"

    private init() {
        map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// 统一用小写扩展名作键；无扩展名返回 nil
    static func key(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// 该文件所属类型的自定义默认应用
    func application(for url: URL) -> URL? {
        guard let ext = Self.key(for: url), let path = map[ext] else { return nil }
        let app = URL(fileURLWithPath: path)
        // 应用被删除或移动后视为未设置，避免打开时报错
        guard FileManager.default.fileExists(atPath: app.path) else { return nil }
        return app
    }

    func application(forExtension ext: String) -> URL? {
        guard let path = map[ext.lowercased()] else { return nil }
        let app = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: app.path) else { return nil }
        return app
    }

    func setApplication(_ app: URL, forExtension ext: String) {
        map[ext.lowercased()] = app.path
        persist()
    }

    func clear(extension ext: String) {
        map.removeValue(forKey: ext.lowercased())
        persist()
    }

    func clearAll() {
        map.removeAll()
        persist()
    }

    /// 显示名（去掉 .app 后缀）
    func displayName(forExtension ext: String) -> String? {
        application(forExtension: ext)?
            .deletingPathExtension()
            .lastPathComponent
    }

    var entries: [(ext: String, app: URL)] {
        map.compactMap { ext, path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (ext, url)
        }
        .sorted { $0.ext < $1.ext }
    }

    private func persist() {
        UserDefaults.standard.set(map, forKey: key)
        // 关联变化后，图标徽标需要重新解析
        DefaultAppService.shared.invalidate()
    }
}
