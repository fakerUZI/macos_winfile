// 安卓文件条目与 `ls -la` 输出解析
import Foundation

struct AndroidEntry: Identifiable, Hashable {
    let name: String
    /// 设备上的绝对路径
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?
    let permissions: String
    /// 可读（用于界面提示）
    let isReadable: Bool

    var id: String { path }

    var url: URL { AndroidURL.make(serial: serial, path: path) }
    /// 所属设备序列号（解析时填入；为空会导致虚拟地址缺少设备标识）
    var serial: String = ""

    /// 大小文本
    var sizeText: String {
        if isDirectory { return "—" }
        return AndroidEntry.formatSize(size)
    }

    var typeDescription: String {
        if isDirectory { return L("android.type.folder", "文件夹") }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? L("android.type.file", "文件") : ext.uppercased() + " " + L("android.type.file", "文件")
    }

    static func formatSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(bytes) B"
            : String(format: "%.1f %@", value, units[index])
    }

    // MARK: - 解析

    /// 解析 `ls -la` 输出。
    ///
    /// 安卓 toybox 的典型行：
    ///   drwxrwx--x  4 root  sdcard_rw   4096 2024-05-01 12:00 Download
    ///   -rw-rw----  1 u0_a123 sdcard_rw 12345 2024-05-01 12:00 note.txt
    ///   lrwxrwxrwx  1 root  root          21 2024-05-01 12:00 sdcard -> /storage/self/primary
    /// 注意：文件名可能含空格，因此按"前 7 列固定 + 剩余全部为文件名"解析。
    static func parseListOutput(_ output: String, parent: String,
                                serial: String = "") -> [AndroidEntry] {
        var entries: [AndroidEntry] = []
        let parentPath = parent.hasSuffix("/") ? String(parent.dropLast()) : parent

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("total ") else { continue }

            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
                .map(String.init)
            guard fields.count >= 7 else { continue }

            let permissions = fields[0]
            guard permissions.count >= 10 else { continue }

            let name: String
            var modified: Date?
            var size: Int64 = 0

            // 依据列数判断时间格式：
            //  7 列（… 大小 日期 时间 名称）  → 标准形式
            //  6 列（… 大小 日期 时间 名称，缺 owner/group 的情况）兜底
            if fields.count >= 8 {
                size = Int64(fields[4]) ?? 0
                name = fields[7]
                modified = parseDate(fields[5], fields[6])
            } else {
                size = Int64(fields[3]) ?? 0
                name = fields[6]
                modified = parseDate(fields[4], fields[5])
            }

            // 跳过 . 与 ..
            guard name != ".", name != ".." else { continue }

            // 处理符号链接：`name -> target`
            var displayName = name
            var isSymlink = false
            if permissions.hasPrefix("l"), let arrow = name.range(of: " -> ") {
                displayName = String(name[name.startIndex..<arrow.lowerBound])
                isSymlink = true
            }

            let fullPath = parentPath.isEmpty ? "/" + displayName : parentPath + "/" + displayName
            let isDirectory = permissions.hasPrefix("d")
            let ownerRead = permissions.count > 1 && permissions[permissions.index(permissions.startIndex, offsetBy: 1)] == "r"

            entries.append(AndroidEntry(
                name: displayName,
                path: fullPath,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: size,
                modified: modified,
                permissions: permissions,
                isReadable: ownerRead,
                serial: serial
            ))
        }
        return entries
    }

    /// 解析 `2024-05-01` `12:00` 形式的日期
    static func parseDate(_ dayField: String, _ timeField: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = formatter.date(from: "\(dayField) \(timeField)") { return date }
        // 某些版本只有日期，时间列为年份
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayField)
    }
}
