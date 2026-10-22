import AppKit
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
        var capacity: UInt64 = 0
        var free: UInt64 = 0
        var id: String { path }
    }

    func device(serial: String) -> AndroidDevice? { devices.first { $0.serial == serial } }
    func roots(for serial: String) -> [AndroidStorage] { storageRoots[serial] ?? [] }
    private var monitor: AndroidDeviceMonitor?
    private var monitorID = UUID()
    private var revision = 0
    private var activationObserver: NSObjectProtocol?
    func startMonitoring() {
        guard monitor == nil else { return }
        let id = UUID()
        monitorID = id
        let tracker = AndroidDeviceMonitor(
            onSnapshot: { [weak self] devices in
                DispatchQueue.main.async {
                    guard let self, self.monitorID == id else { return }
                    self.applySnapshot(devices)
                }
            },
            onFailure: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.monitorID == id else { return }
                    self.lastError = message
                }
            })
        monitor = tracker
        tracker.start()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stopMonitoring() {
        monitorID = UUID()
        monitor?.stop()
        monitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let expected = revision
        let result = await Task.detached(priority: .utility) { Result { try MTPRunner.scan() } }.value
        guard expected == revision else { return }
        switch result {
        case .success(let found): applySnapshot(found)
        case .failure(let error): lastError = error.localizedDescription
        }
    }

    func applySnapshot(_ found: [AndroidDevice]) {
        revision += 1
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.serial).inserted }
        let roots = Dictionary(
            unique.filter(\.isReady).map { device in
                (
                    device.serial,
                    device.storages.map {
                        AndroidStorage(
                            label: $0.label, path: $0.path, isRemovable: $0.isRemovable, capacity: $0.capacity,
                            free: $0.free)
                    }
                )
            }, uniquingKeysWith: { a, _ in a })
        if storageRoots != roots { storageRoots = roots }
        if devices != unique { devices = unique }
        lastError = nil
    }
}
