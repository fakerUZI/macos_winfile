// 安卓设备枚举与状态
import Foundation

@MainActor
final class AndroidDeviceService: ObservableObject {

    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var isScanning = false
    @Published var lastError: String?

    /// 是否有设备待授权（用于界面提示）
    var hasUnauthorizedDevice: Bool { devices.contains { $0.isUnauthorized } }

    /// 刷新设备列表
    func refresh() async {
        guard AdbRunner.isAvailable else {
            devices = []
            lastError = AdbError.notInstalled.localizedDescription
            return
        }
        isScanning = true
        defer { isScanning = false }

        let list: [AndroidDevice] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let result = try? AdbRunner.run(["devices", "-l"], timeout: 10) else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: Self.parseDevices(result.stdout))
            }
        }

        // 补充机型等信息（逐个查询，失败不影响列表）
        var enriched: [AndroidDevice] = []
        for var device in list where device.isReady {
            let props: [String: String] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let result = try? AdbRunner.run(
                        ["-s", device.serial, "shell", "getprop"], timeout: 8) else {
                        continuation.resume(returning: [:])
                        return
                    }
                    continuation.resume(returning: Self.parseGetProp(result.stdout))
                }
            }
            device.model = props["ro.product.model"] ?? device.model
            device.product = props["ro.product.name"] ?? device.product
            device.device = props["ro.product.device"] ?? device.device
            device.androidVersion = props["ro.build.version.release"] ?? ""
            enriched.append(device)
        }
        // 未授权的设备也保留在列表中，便于提示用户
        enriched.append(contentsOf: list.filter { !$0.isReady })
        devices = enriched
        if enriched.isEmpty { lastError = nil }
    }

    /// 解析 `adb devices -l` 输出
    nonisolated static func parseDevices(_ output: String) -> [AndroidDevice] {
        var result: [AndroidDevice] = []
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty,
                  !text.hasPrefix("List of devices"),
                  !text.hasPrefix("*") else { continue }
            let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]
            var device = AndroidDevice(serial: serial, model: "", product: "", device: "",
                                       state: state, androidVersion: "", transportID: "")
            for part in parts.dropFirst(2) where part.contains(":") {
                let pair = part.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "model": device.model = pair[1]
                case "product": device.product = pair[1]
                case "device": device.device = pair[1]
                case "transport_id": device.transportID = pair[1]
                default: break
                }
            }
            result.append(device)
        }
        return result
    }

    /// 解析 `getprop` 输出（形如 [key]: [value]）
    nonisolated static func parseGetProp(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
