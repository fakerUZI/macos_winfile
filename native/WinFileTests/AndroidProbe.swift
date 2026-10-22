import Foundation

struct AndroidProbeResult {
    let mtpAvailable: Bool
    let readySerials: [String]
    let unavailableCount: Int
    let storageRoot: String?
    let canListStorage: Bool
    var isUsable: Bool { mtpAvailable && !readySerials.isEmpty && canListStorage }
    var summary: String {
        if !mtpAvailable { return MTPError.unavailable.localizedDescription }
        if readySerials.isEmpty {
            return unavailableCount > 0
                ? MTPError.operation("locked").localizedDescription : L("android.probe.noDevice", "未检测到安卓设备")
        }
        if !canListStorage { return L("android.probe.noStorage", "无法读取设备存储") }
        return L("android.probe.ready", "已连接 %d 台设备", readySerials.count)
    }
}

enum AndroidProbe {
    static func run() -> AndroidProbeResult {
        let devices = (try? MTPRunner.scan()) ?? []
        let ready = devices.filter(\.isReady)
        let root = ready.first?.storages.first?.path
        let canList =
            root.flatMap { path in ready.first.map { (try? AndroidFileService(serial: $0.serial).list(path)) != nil } }
            ?? false
        return AndroidProbeResult(
            mtpAvailable: MTPRunner.isAvailable, readySerials: ready.map(\.serial),
            unavailableCount: devices.filter { !$0.isReady }.count, storageRoot: root, canListStorage: canList)
    }
}
