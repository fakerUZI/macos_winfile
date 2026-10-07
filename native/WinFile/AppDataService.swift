// 应用数据目录扫描
//
// 用途：列出各应用（含沙盒容器）的数据目录，让用户用 WinFile 浏览其中的普通文件。
//
// 重要限制（macOS 隐私保护）：
//   macOS 10.14 起，读取【其它应用】的容器需要「完整磁盘访问权限」，
//   该权限只能由用户在「系统设置 → 隐私与安全性 → 完整磁盘访问权限」中手动授予，
//   应用自身无法申请。未授权时目录会返回「操作不允许」。
//   一旦应用启用沙盒（上架 App Store 的形态），此功能永久不可用。
import AppKit
import Foundation

/// 一个应用的数据目录
struct AppDataItem: Identifiable, Hashable {
    let id: String
    /// 展示名称（如「微信」）
    let name: String
    /// Bundle 标识（如 com.tencent.xinWeChat）
    let bundleID: String
    /// 数据目录（容器 Data 目录或 Application Support 下的目录）
    let dataURL: URL
    /// 应用本体位置（若可定位）
    let appURL: URL?
    /// 是否来自沙盒容器
    let isContainer: Bool

    /// 数据目录是否可读
    var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: dataURL.path)
    }
}

enum AppDataService {

    /// 常见应用的中文名（系统接口取不到时兜底）
    private static let knownNames: [String: String] = [
        "com.tencent.xinWeChat": "微信",
        "com.tencent.qq": "QQ",
        "com.tencent.WeWorkMac": "企业微信",
        "com.apple.Safari": "Safari 浏览器",
        "com.apple.mail": "邮件",
        "com.apple.iChat": "信息",
        "com.apple.dt.Xcode": "Xcode",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.google.Chrome": "Google Chrome",
        "com.spotify.client": "Spotify",
        "com.apple.Photos": "照片",
        "com.apple.Music": "音乐",
        "com.apple.iCal": "日历",
        "com.apple.Notes": "备忘录",
        "com.apple.reminders": "提醒事项",
    ]

    /// 扫描应用数据目录。
    /// - Parameter includeUnreadable: 是否包含不可读的条目（用于提示用户授权）
    static func scan(includeUnreadable: Bool = true) -> [AppDataItem] {
        var items: [AppDataItem] = []
        let fm = FileManager.default
        let home = FileSystemService.realHomeDirectory()

        // 1) 沙盒应用容器：~/Library/Containers/<bundleID>/Data
        let containers = home.appendingPathComponent("Library/Containers")
        if let entries = try? fm.contentsOfDirectory(at: containers,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) {
            for entry in entries {
                guard entry.pathExtension != "plist" else { continue }
                let bundleID = entry.lastPathComponent
                let data = entry.appendingPathComponent("Data")
                guard fm.fileExists(atPath: data.path) else { continue }
                // 跳过系统自带的大量容器，保留用户关心且有内容的
                let item = makeItem(bundleID: bundleID, dataURL: data, isContainer: true)
                if item.isReadable || includeUnreadable {
                    if isInteresting(item) { items.append(item) }
                }
            }
        }

        // 2) 非沙盒应用数据：~/Library/Application Support/<名称>
        let support = home.appendingPathComponent("Library/Application Support")
        if let entries = try? fm.contentsOfDirectory(at: support,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) {
            for entry in entries {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let name = entry.lastPathComponent
                // 跳过明显不是应用数据的目录
                guard !name.hasPrefix("com.apple."), !name.hasPrefix("."),
                      name != "Code" && name != "CrashReporter" else { continue }
                items.append(AppDataItem(id: "support:" + name,
                                         name: name,
                                         bundleID: name,
                                         dataURL: entry,
                                         appURL: nil,
                                         isContainer: false))
            }
        }

        // 去重 + 排序：有名字的优先，其次按名称
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        return unique.sorted {
            if $0.isReadable != $1.isReadable { return $0.isReadable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 构造条目并解析应用名
    private static func makeItem(bundleID: String, dataURL: URL, isContainer: Bool) -> AppDataItem {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        var name = knownNames[bundleID]
        if name == nil, let appURL {
            name = FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        if name == nil {
            // 回退：取 Bundle 标识的最后一段并去掉常见前缀
            let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            name = tail
        }
        return AppDataItem(id: "container:" + bundleID,
                           name: name ?? bundleID,
                           bundleID: bundleID,
                           dataURL: dataURL,
                           appURL: appURL,
                           isContainer: isContainer)
    }

    /// 过滤掉纯系统噪音：保留用户可识别的应用，或确实有内容的目录
    private static func isInteresting(_ item: AppDataItem) -> Bool {
        if knownNames[item.bundleID] != nil { return true }
        if item.appURL != nil { return true }          // 能定位到 .app 说明是用户安装的应用
        // 系统容器：仅保留确实有可读内容的
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: item.dataURL.path) else {
            return false
        }
        return !contents.filter { !$0.hasPrefix(".") }.isEmpty
    }

    /// 判断当前是否"足够可用"：只要多数应用数据目录可读，就无需提示授权。
    ///
    /// 说明：系统内置应用的容器（如 Safari）即使用户授予完整磁盘访问也可能仍不可读，
    /// 因此不能用它们做硬性判据 —— 否则会在功能实际可用时误报"需要授权"。
    static func hasSufficientAccess(_ items: [AppDataItem]) -> Bool {
        guard !items.isEmpty else { return true }
        let readable = items.filter { $0.isReadable }.count
        // 可读比例超过一半即视为可用
        return Double(readable) / Double(items.count) > 0.5
    }
}
