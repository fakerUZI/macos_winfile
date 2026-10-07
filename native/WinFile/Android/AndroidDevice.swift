// Android 设备访问（通过 adb）
//
// 背景：macOS 不支持原生访问 Android 文件（MTP 无系统支持），
// 因此安卓相关功能只能通过 adb 命令行工具实现。
// 这是本项目唯一使用子进程的地方，仅作用于安卓设备，
// 本地文件仍走纯原生 FileManager/URL 通道。
import Foundation

/// 一台安卓设备
struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    var model: String
    var product: String
    var device: String
    var state: String          // device / unauthorized / offline
    var androidVersion: String
    var transportID: String

    var id: String { serial }

    /// 展示名称：优先机型，其次序列号
    var displayName: String {
        let name = model.isEmpty ? product : model
        let cleaned = name.replacingOccurrences(of: "_", with: " ")
        return cleaned.isEmpty ? serial : cleaned
    }

    var isReady: Bool { state == "device" }
    var isUnauthorized: Bool { state == "unauthorized" }
}
