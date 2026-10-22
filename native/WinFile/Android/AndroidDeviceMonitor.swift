import Foundation

/// Descriptor-only presence checks stay independent of the serialized MTP transfer session.
/// Scan on insertion and retry locked/busy phones; removal is published without claiming USB.
final class AndroidDeviceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var scanning = false
    private var revision = 0
    private var devices: [AndroidDevice] = []
    private var lastPresence: Set<String> = []
    private var lastScan = Date.distantPast
    private let wake = DispatchSemaphore(value: 0)
    private let presence: @Sendable () throws -> Set<String>
    private let scan: @Sendable () throws -> [AndroidDevice]?
    private let interval: TimeInterval
    private let refreshInterval: TimeInterval
    private let onSnapshot: @Sendable ([AndroidDevice]) -> Void
    private let onFailure: @Sendable (String) -> Void
    init(
        onSnapshot: @escaping @Sendable ([AndroidDevice]) -> Void, onFailure: @escaping @Sendable (String) -> Void,
        presence: @escaping @Sendable () throws -> Set<String> = { try MTPRunner.presence() },
        scan: @escaping @Sendable () throws -> [AndroidDevice]? = { try MTPRunner.tryScan() },
        interval: TimeInterval = 1.5, refreshInterval: TimeInterval = 8
    ) {
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
        self.presence = presence
        self.scan = scan
        self.interval = interval
        self.refreshInterval = refreshInterval
    }

    func start() {
        DispatchQueue(label: "WinFile.MTP.Presence", qos: .utility).async { [self] in
            while true {
                lock.lock()
                let done = stopped
                lock.unlock()
                if done { return }
                do { observe(try presence()) } catch { onFailure(error.localizedDescription) }
                _ = wake.wait(timeout: .now() + interval)
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        revision += 1
        lock.unlock()
        wake.signal()
    }

    private func observe(_ presence: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let changed = presence != lastPresence
        if changed {
            revision += 1
            lastPresence = presence
            devices = devices.filter { presence.contains($0.transportID) }
            TabDiagnostics.recordTransport("mtp.presence", detail: presence.sorted().joined(separator: ","))
            onSnapshot(devices)
        }
        // Recheck ready devices too: lock/USB-mode changes may not alter the USB address.
        guard !scanning, !presence.isEmpty, changed || Date().timeIntervalSince(lastScan) >= refreshInterval else {
            return
        }
        scanning = true
        let expected = revision
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { try scan() }
            lock.lock()
            defer { lock.unlock() }
            scanning = false
            guard !stopped, revision == expected else { return }
            switch result {
            case .success(let found):
                guard let found else { return }
                lastScan = Date()
                devices = found.filter { lastPresence.contains($0.transportID) }
                onSnapshot(devices)
            case .failure(let error):
                lastScan = Date()
                onFailure(error.localizedDescription)
            }
        }
    }
}
