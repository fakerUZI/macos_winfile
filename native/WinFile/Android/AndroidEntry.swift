// MTP 文件条目；保留对象 ID 与存储 ID，不依赖 shell 输出。
import Foundation

struct AndroidEntry: Identifiable, Hashable {
    let name: String
    /// MTP 存储内的绝对虚拟路径
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { path }

    var url: URL { AndroidURL.make(serial: serial, path: path) }
    /// 所属 MTP 设备序列号
    var serial: String = ""
    var objectID: UInt32 = 0
    var storageID: UInt32 = 0
    var displayName: String? = nil
}
