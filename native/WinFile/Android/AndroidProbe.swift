// 安卓连通性探测（供测试与界面预检使用）
//
// 汇总一次设备可用性检查：adb 是否存在、是否有已授权设备、
// 存储根是否可读。避免在界面上逐个判断。
import Foundation

struct AndroidProbeResult {
    let adbAvailable: Bool
    let adbPath: String?
    let deviceCount: Int
    let readySerials: [String]
    let unauthorizedCount: Int
    let storageRoot: String?
    let canListStorage: Bool

    var isUsable: Bool { adbAvailable && !readySerials.isEmpty && canListStorage }

    var summary: String {
        if !adbAvailable { return L("android.probe.noAdb", "未安装 adb") }
        if readySerials.isEmpty {
            return unauthorizedCount > 0
                ? L("android.probe.unauthorized", "设备待授权：请在平板上点「允许 USB 调试」")
                : L("android.probe.noDevice", "未检测到安卓设备")
        }
        if !canListStorage { return L("android.probe.noStorage", "无法读取设备存储") }
        return L("android.probe.ready", "已连接 %d 台设备", readySerials.count)
    }
}

enum AndroidProbe {

    /// 同步探测（调用方负责放到后台线程）
    static func run() -> AndroidProbeResult {
        guard let adbPath = AdbRunner.adbPath() else {
            return AndroidProbeResult(adbAvailable: false, adbPath: nil, deviceCount: 0,
                                      readySerials: [], unauthorizedCount: 0,
                                      storageRoot: nil, canListStorage: false)
        }
        guard let result = try? AdbRunner.run(["devices", "-l"], timeout: 10) else {
            return AndroidProbeResult(adbAvailable: true, adbPath: adbPath, deviceCount: 0,
                                      readySerials: [], unauthorizedCount: 0,
                                      storageRoot: nil, canListStorage: false)
        }
        let devices = AndroidDeviceService.parseDevices(result.stdout)
        let ready = devices.filter { $0.isReady }.map(\.serial)
        let unauthorized = devices.filter { $0.isUnauthorized }.count

        var root: String?
        var canList = false
        if let serial = ready.first {
            let service = AndroidFileService(serial: serial)
            let resolved = service.resolveRoot()
            root = resolved
            if let listing = try? AdbRunner.run(
                ["-s", serial, "shell", "ls", service.shellQuote(resolved)], timeout: 10) {
                canList = listing.ok && !listing.stdout.isEmpty
            }
        }

        return AndroidProbeResult(adbAvailable: true, adbPath: adbPath,
                                  deviceCount: devices.count, readySerials: ready,
                                  unauthorizedCount: unauthorized,
                                  storageRoot: root, canListStorage: canList)
    }
}
