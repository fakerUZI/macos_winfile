// 安卓设备注册表
//
// 界面各处（侧边栏、页签标题、导航）都需要按序列号查到设备信息，
// 这里集中保存最近一次枚举结果，避免重复调用 adb。
import Foundation

@MainActor
final class AndroidDeviceRegistry: ObservableObject {
    static let shared = AndroidDeviceRegistry()

    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var storageRoots: [String: [AndroidStorage]] = [:]
    @Published private(set) var isRefreshing = false
    @Published var lastError: String?

    struct AndroidStorage: Identifiable, Hashable {
        let label: String
        let path: String
        let isRemovable: Bool
        var id: String { path }
    }

    func device(serial: String) -> AndroidDevice? {
        devices.first { $0.serial == serial }
    }

    func roots(for serial: String) -> [AndroidStorage] {
        storageRoots[serial] ?? []
    }

    /// 刷新设备列表（后台执行 adb 调用）
    func refresh() async {
        guard AdbRunner.isAvailable else {
            devices = []
            lastError = AdbError.notInstalled.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let found: [AndroidDevice] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let result = try? AdbRunner.run(["devices", "-l"], timeout: 10) else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: AndroidDeviceService.parseDevices(result.stdout))
            }
        }

        var enriched: [AndroidDevice] = []
        var roots: [String: [AndroidStorage]] = [:]
        for var device in found {
            if device.isReady {
                let (props, storages) = await Self.loadDeviceDetail(serial: device.serial)
                device.model = props["ro.product.model"] ?? device.model
                device.androidVersion = props["ro.build.version.release"] ?? ""
                roots[device.serial] = storages
            }
            enriched.append(device)
        }
        devices = enriched
        storageRoots = roots
        lastError = nil
    }

    private static func loadDeviceDetail(serial: String) async -> ([String: String], [AndroidStorage]) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var props: [String: String] = [:]
                if let result = try? AdbRunner.run(["-s", serial, "shell", "getprop"], timeout: 10) {
                    props = AndroidDeviceService.parseGetProp(result.stdout)
                }
                let storages = AndroidDeviceRegistry.detectStorage(serial: serial)
                continuation.resume(returning: (props, storages))
            }
        }
    }

    /// 探测可用存储位置。
    ///
    /// 「内部存储」几乎总是存在；「SD 卡」通过 `/storage` 下的可移动卷判断，
    /// 排除 emulated/self 这类系统路径。
    nonisolated static func detectStorage(serial: String) -> [AndroidStorage] {
        var result: [AndroidStorage] = []

        // 内部存储
        let internalPaths = ["/storage/emulated/0", "/sdcard"]
        for path in internalPaths {
            if let check = try? AdbRunner.run(["-s", serial, "shell", "ls", "-d", path], timeout: 8),
               check.ok {
                result.append(AndroidStorage(label: L("android.storage.internal", "内部存储"),
                                             path: "/storage/emulated/0",
                                             isRemovable: false))
                break
            }
        }

        // 可移动存储（SD 卡 / U 盘）
        if let listing = try? AdbRunner.run(["-s", serial, "shell", "ls", "/storage"], timeout: 8),
           listing.ok {
            for line in listing.stdout.split(separator: "\n") {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty,
                      name != "emulated",
                      name != "self",
                      !name.hasPrefix(".") else { continue }
                // 只有确实是目录才纳入
                let path = "/storage/" + name
                if let check = try? AdbRunner.run(["-s", serial, "shell", "ls", "-d", path], timeout: 8),
                   check.ok {
                    result.append(AndroidStorage(
                        label: name.uppercased().contains("SD") || name.count <= 12
                            ? L("android.storage.sd", "SD 卡（%@）", name)
                            : L("android.storage.removable", "外部存储（%@）", name),
                        path: path,
                        isRemovable: true))
                }
            }
        }
        return result
    }
}
