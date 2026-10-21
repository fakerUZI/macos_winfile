// 照片导出时的文件命名
//
// 说明：照片图库里的原文件可能同名（IMG_0001.HEIC），导出到同一目录时必须
// 生成不冲突的名称，否则 writeData 会覆盖或失败。这里只做纯路径计算，
// 不依赖 Photos 框架，便于命令行测试覆盖。
import Foundation

enum PhotoExportNaming {

    /// 在目录中为 `preferredName` 找一个不冲突的 URL。
    ///
    /// 规则：已存在时依次尝试 "名称 2.扩展名"、"名称 3.扩展名"…
    /// 也处理了没有扩展名、以及名称本身就是空字符串的情况。
    static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let trimmed = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Photo" : trimmed
        let nsName = fallback as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        func candidate(_ index: Int) -> URL {
            let name: String
            if index <= 1 {
                name = fallback
            } else {
                name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            }
            return directory.appendingPathComponent(name)
        }

        var index = 1
        var url = candidate(index)
        while fm.fileExists(atPath: url.path) {
            index += 1
            url = candidate(index)
        }
        return url
    }

    /// 用创建时间生成可读的默认名称（图库资源没有可用文件名时使用）
    static func datedName(for date: Date?, extension ext: String, index: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date ?? Date())
        let base = "Photo-\(stamp)"
        let suffix = index > 0 ? "-\(index + 1)" : ""
        return ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
    }
}
