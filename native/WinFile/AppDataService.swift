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
    /// 原始 Bundle 标识（UUID 容器被推断出应用名后，原 UUID 保留在此，便于排查）
    var originalBundleID: String?

    /// 数据目录是否可读
    var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: dataURL.path)
    }
}

enum AppDataService {

    /// 常见应用的中文名（系统接口取不到时兜底）
    private static var knownNames: [String: String] { [
        "com.tencent.xinWeChat": L("appData.name.com.tencent.xinWeChat", "微信"),
        "com.tencent.qq": "QQ",
        "com.tencent.WeWorkMac": L("appData.name.com.tencent.WeWorkMac", "企业微信"),
        "com.apple.Safari": L("appData.name.com.apple.Safari", "Safari 浏览器"),
        "com.apple.mail": L("appData.name.com.apple.mail", "邮件"),
        "com.apple.iChat": L("appData.name.com.apple.iChat", "信息"),
        "com.apple.dt.Xcode": "Xcode",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.google.Chrome": "Google Chrome",
        "com.spotify.client": "Spotify",
        "com.apple.Photos": L("appData.name.com.apple.Photos", "照片"),
        "com.apple.Music": L("appData.name.com.apple.Music", "音乐"),
        "com.apple.iCal": L("appData.name.com.apple.iCal", "日历"),
        "com.apple.Notes": L("appData.name.com.apple.Notes", "备忘录"),
        "com.apple.reminders": L("appData.name.com.apple.reminders", "提醒事项"),
    ] }

    static func localizedName(for item: AppDataItem) -> String { knownNames[item.bundleID] ?? item.name }

    /// 扫描应用数据目录。
    /// - Parameters:
    ///   - includeUnreadable: 是否包含不可读的条目（用于提示用户授权）
    ///   - includeEmptyShells: 是否包含空壳容器（默认不包含）
    static func scan(includeUnreadable: Bool = true,
                     includeEmptyShells: Bool = false) -> [AppDataItem] {
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
                var item = makeItem(bundleID: bundleID, dataURL: data, isContainer: true)
                // UUID 命名的容器：尝试从内容推断归属应用，给出可读名称
                if isUUID(bundleID) {
                    if !includeEmptyShells, isEmptyShell(bundleID: bundleID, dataURL: data) {
                        continue   // 空壳：UUID 命名且无实际内容
                    }
                    if let inferred = inferBundleID(inContainer: data) {
                        item = AppDataItem(id: item.id,
                                           name: resolvedName(for: inferred) ?? inferred,
                                           bundleID: inferred,
                                           dataURL: item.dataURL,
                                           appURL: NSWorkspace.shared.urlForApplication(
                                               withBundleIdentifier: inferred),
                                           isContainer: true,
                                           originalBundleID: bundleID)
                    }
                }
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

    // MARK: - 从容器内容推断归属应用

    /// 从容器内容里的 Bundle 标识推断归属应用。
    ///
    /// 背景：部分容器以 UUID 命名（读不到 container-manager 元数据，被系统保护），
    /// 但容器内的文件路径常带有应用的 Bundle 标识，例如
    ///   Library/HTTPStorages/com.tencent.weread.modernWidget/httpstorages.sqlite
    /// 由此可以还原出「微信读书」这样的可读名称。
    ///
    /// 取不到线索时返回 nil，界面继续显示 UUID。
    static func inferBundleID(inContainer dataURL: URL) -> String? {
        let fm = FileManager.default
        // 已知会出现 Bundle 标识的位置（按命中概率排序）
        let candidates = ["Library/Application Support", "Library/HTTPStorages",
                          "Library/Preferences", "Library/Caches", "Library"]
        var votes: [String: Int] = [:]

        for relative in candidates {
            let directory = dataURL.appendingPathComponent(relative)
            guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                // 去掉扩展名与可能的目录后缀，取得 Bundle 形态的标识
                var name = entry
                if name.hasSuffix(".plist") || name.hasSuffix(".sqlite")
                    || name.hasSuffix("-wal") || name.hasSuffix("-shm") {
                    name = (name as NSString).deletingPathExtension
                }
                guard looksLikeBundleID(name) else { continue }
                votes[name, default: 0] += 1
            }
            // 找到足够线索就不再往下找
            if votes.count >= 3 { break }
        }

        // 取出现次数最多的；同票时选最短（通常是最上层、最干净的标识）
        return votes.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.count > rhs.key.count : lhs.value < rhs.value
        }?.key
    }

    /// 是否像 Bundle 标识（反向域名，至少三段，且含字母）
    static func looksLikeBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count >= 3 else { return false }
        // 段必须是字母/数字/连字符/下划线，且整体含字母
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy { allowed.contains($0) } }) else { return false }
        guard value.rangeOfCharacter(from: .letters) != nil else { return false }
        // 排除纯版本号形态（如 10.2.0.85）
        let hasLetterPart = parts.contains { $0.rangeOfCharacter(from: .letters) != nil }
        return hasLetterPart
    }

    // MARK: - 空壳容器判定

    /// 由 Bundle 标识解析显示名（已知表 → 系统查询 → 标识本身）
    static func resolvedName(for bundleID: String) -> String? {
        if let known = knownNames[bundleID] { return known }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: appURL.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return nil
    }

    /// 判断是否为"空壳容器"。
    ///
    /// 背景：macOS 会为沙盒应用预建目录骨架（Desktop/Documents/Downloads/…），
    /// 若应用未写入数据就留下一个几乎为空的容器。这类容器通常以 UUID 命名，
    /// 在界面上显示为一串无意义的编号，因此默认从列表中剔除。
    ///
    /// 判定条件（三个同时成立才算空壳，避免误删有内容的容器）：
    ///   1. 名字是 UUID 形式（有应用标识的容器一律保留）
    ///   2. 常见数据目录与 Library 中都没有文件
    ///   3. 整个容器体积很小（< 100 KB）
    static func isEmptyShell(bundleID: String, dataURL: URL) -> Bool {
        // 条件 1：UUID 形式
        guard isUUID(bundleID) else { return false }

        let fm = FileManager.default
        // 条件 2：常见数据目录与 Library 中都没有文件
        let checked = ["Documents", "Downloads", "Desktop",
                       "Pictures", "Movies", "Music", "Library"]
        for name in checked {
            if containsAnyFile(dataURL.appendingPathComponent(name), fileManager: fm) {
                return false
            }
        }
        // 条件 3：整体体积很小
        return directorySize(dataURL, fileManager: fm) < 100 * 1024
    }

    /// 名字是否为 UUID 形式（8-4-4-4-12 的十六进制）
    static func isUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { hex.contains($0) }
        }
    }

    /// 目录（含子目录）中是否存在文件
    private static func containsAnyFile(_ directory: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
    }

    /// 目录总大小（字节）
    private static func directorySize(_ directory: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
