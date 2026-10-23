import Darwin
import Foundation

enum MTPError: LocalizedError {
    case unavailable, timeout, noDevice, protocolError
    case operation(String)
    var diagnosticCode: String {
        switch self {
        case .unavailable: return "helperUnavailable"
        case .timeout: return "timeout"
        case .noDevice: return "noDevice"
        case .protocolError: return "protocol"
        case .operation(let code): return String(code.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        }
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: return L("android.mtp.missing", "MTP 组件缺失，请重新安装 LeafFiles。")
        case .timeout: return L("android.mtp.timeout", "设备响应超时，请检查连接、解锁手机并选择「文件传输」后重试。")
        case .noDevice: return L("android.error.noDevice", "没有可用的安卓设备")
        case .protocolError: return L("android.mtp.protocol", "无法读取 MTP 响应，请重试。")
        case .operation(let code):
            switch code {
            case "noDevice", "deviceChanged": return MTPError.noDevice.localizedDescription
            case "locked", "usb": return L("android.mtp.connect", "请解锁手机并选择 USB「文件传输」，关闭其他占用设备的传输软件后重试。")
            case "exists": return L("android.mtp.exists", "目标已存在同名文件或文件夹，未覆盖。")
            case "notFound": return L("android.mtp.notFound", "设备上的项目已不存在，请刷新目录。")
            case "unsupportedMove": return L("android.mtp.moveUnsupported", "此设备不支持 MTP 内部移动。请先复制，确认完成后再删除原文件。")
            case "invalidPath", "invalidName", "recursive", "storageRoot", "ambiguous":
                return L("android.mtp.invalid", "此文件名、路径或操作无效，未修改文件。")
            case "localRead", "localWrite": return L("android.mtp.local", "无法读写本机文件，请检查权限、剩余空间和目标名称。符号链接不支持上传。")
            case "transfer": return L("android.mtp.transfer", "传输未完成，请检查设备连接后重试。")
            case "unsupportedRead", "partialRead":
                return L("android.stream.unsupported", "设备无法完成分段读取，已停止播放。未自动下载完整视频；如需本机播放，请手动下载。")
            case "fileChanged": return L("android.stream.changed", "设备上的视频已变化，已停止播放。请重新打开。")
            case "range": return MTPError.protocolError.localizedDescription
            default: return L("android.mtp.failed", "MTP 操作失败，请确认手机允许访问该位置后重试。")
            }
        }
    }
}

struct MTPStorage: Decodable, Hashable {
    let id: UInt32
    let path: String
    let label: String
    let isRemovable: Bool
    let capacity: UInt64
    let free: UInt64
}

struct MTPDeviceInfo: Decodable {
    let serial: String
    let model: String
    let transportID: String
    let state: String
    let storages: [MTPStorage]
    var device: AndroidDevice {
        AndroidDevice(serial: serial, model: model, state: state, transportID: transportID, storages: storages)
    }
}

struct MTPObject: Decodable {
    let name: String
    let path: String
    let objectID: UInt32
    let storageID: UInt32
    let isDirectory: Bool
    let size: UInt64
    let modified: Int64
    var displayName: String? = nil
    func entry(serial: String) throws -> AndroidEntry {
        guard AndroidFileService.validName(name), path.hasPrefix("/"), !path.contains("\0"),
            name == (path as NSString).lastPathComponent, size <= UInt64(Int64.max)
        else { throw MTPError.protocolError }
        return AndroidEntry(
            name: name, path: path, isDirectory: isDirectory,
            size: Int64(size), modified: modified > 0 ? Date(timeIntervalSince1970: Double(modified)) : nil,
            serial: serial, objectID: objectID, storageID: storageID, displayName: displayName)
    }
}

struct MTPResult: Decodable {
    var devices: [MTPDeviceInfo]?
    var transports: [String]?
    var entries: [MTPObject]?
    var entry: MTPObject?
    var bytes: String?
}

/// One transport implementation: libmtp in the bundled helper. No shell commands or PATH lookup.
/// Sessions are serialized; presence probes inspect descriptors without claiming the USB interface.
enum MTPRunner {
    private static let session = NSRecursiveLock()
    private static let childLock = NSLock()
    private nonisolated(unsafe) static var children: [Int32: Process] = [:]
    static func stopAll() {
        childLock.lock()
        let active = Array(children.values)
        childLock.unlock()
        for child in active where child.isRunning { child.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            for child in active where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
    private nonisolated(unsafe) static var attachments: [String: String] = [:]
    private nonisolated(unsafe) static var lastDeviceSummary: String?
    static func helperURL() -> URL? {
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WinFileMTP")
        if FileManager.default.isExecutableFile(atPath: bundle.path) { return bundle }
        // CLI tests are built beside the development helper; apps only use their own bundled copy.
        if Bundle.main.bundleURL.pathExtension != "app" {
            let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("mtp/WinFileMTP")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    static var isAvailable: Bool { helperURL() != nil }
    static func scan() throws -> [AndroidDevice] {
        session.lock()
        defer { session.unlock() }
        let list = try request(["op": "scan"], timeout: 20).devices ?? []
        attachments = Dictionary(list.map { ($0.serial, $0.transportID) }, uniquingKeysWith: { a, _ in a })
        let devices = list.map(\.device)
        let summary = devices.map(\.diagnosticSummary).sorted().joined(separator: " | ")
        if summary != lastDeviceSummary {
            lastDeviceSummary = summary
            TabDiagnostics.recordTransport("mtp.devices", detail: summary.isEmpty ? "none" : summary)
        }
        return devices
    }

    static func tryScan() throws -> [AndroidDevice]? {
        guard session.try() else { return nil }
        defer { session.unlock() }
        return try scan()
    }

    static func attachmentID(serial: String) -> String {
        session.lock()
        defer { session.unlock() }
        return attachments[serial] ?? ""
    }

    static func presence() throws -> Set<String> { Set(try request(["op": "presence"], timeout: 6).transports ?? []) }
    static func run(
        _ operation: String, serial: String, path: String = "/", values: [String: Any] = [:],
        cancellation: ScanCancellation? = nil, progress: ((Double?) -> Void)? = nil,
        expectedTransport: String? = nil
    ) throws -> MTPResult {
        // Poll the lock so cancelling a queued request does not wait for another transfer.
        while !session.try() {
            if cancellation?.isCancelled == true { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { session.unlock() }
        if cancellation?.isCancelled == true { throw CancellationError() }
        if attachments[serial] == nil { _ = try scan() }
        guard let transport = attachments[serial] else { throw MTPError.noDevice }
        if let expectedTransport, expectedTransport != transport { throw MTPError.noDevice }
        return try reconnectingRead(
            operation: operation, transport: transport,
            refresh: {
                _ = try scan()
                return attachments[serial]
            }
        ) { currentTransport in
            if cancellation?.isCancelled == true { throw CancellationError() }
            var requestValues = values
            requestValues["op"] = operation
            requestValues["serial"] = serial
            requestValues["transport"] = currentTransport
            requestValues["path"] = path
            return try request(
                requestValues, timeout: ["pull", "push"].contains(operation) ? 3600 : 30,
                cancellation: cancellation, progress: progress)
        }
    }

    /// Refresh a stale attachment once for metadata reads only. The lookup remains
    /// pinned to the original serial; swapping devices must never retarget a request.
    static func reconnectingRead(
        operation: String, transport: String, refresh: () throws -> String?,
        request: (String) throws -> MTPResult
    ) throws -> MTPResult {
        do { return try request(transport) } catch MTPError.operation(let code)
            where ["list", "stat"].contains(operation)
            && ["noDevice", "deviceChanged"].contains(code)
        {
            guard let current = try refresh(), current != transport else { throw MTPError.operation(code) }
            TabDiagnostics.recordTransport("mtp.read.reconnect", detail: "op=\(operation) usb=\(transport)->\(current)")
            return try request(current)
        }
    }

    private static func request(
        _ values: [String: Any], timeout: TimeInterval,
        cancellation: ScanCancellation? = nil, progress: ((Double?) -> Void)? = nil
    ) throws -> MTPResult {
        guard let helper = helperURL() else { throw MTPError.unavailable }
        let started = Date()
        do {
            let result = try execute(
                executable: helper, input: JSONSerialization.data(withJSONObject: values), timeout: timeout,
                cancellation: cancellation, onProgress: progress)
            let envelope = try JSONDecoder().decode(MTPEnvelope.self, from: result)
            if let error = envelope.error {
                if error == "cancelled" { throw CancellationError() }
                throw MTPError.operation(error)
            }
            guard let value = envelope.result else { throw MTPError.protocolError }
            return value
        } catch {
            if !(error is CancellationError) {
                let code = (error as? MTPError)?.diagnosticCode ?? "\(type(of: error)):\((error as NSError).code)"
                TabDiagnostics.recordTransport(
                    "mtp.request.error",
                    detail:
                        "op=\(values["op"] as? String ?? "?") usb=\(values["transport"] as? String ?? "-") code=\(code) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))"
                )
            }
            throw error
        }
    }

    private struct MTPEnvelope: Decodable {
        let result: MTPResult?
        let error: String?
    }

    static func readChunk(from handle: FileHandle) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    /// JSON-lines: progress is consumed immediately, only the final response is retained.
    static func execute(
        executable: URL, arguments: [String] = [], input: Data = Data(), timeout: TimeInterval,
        cancellation: ScanCancellation? = nil, onProgress: ((Double?) -> Void)? = nil
    ) throws -> Data {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = stdin
        child.standardOutput = output
        child.standardError = errors
        try child.run()
        childLock.lock()
        children[child.processIdentifier] = child
        childLock.unlock()
        defer {
            childLock.lock()
            children.removeValue(forKey: child.processIdentifier)
            childLock.unlock()
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        let records = MTPRecords(onProgress: onProgress)
        let diagnostics = MTPDiagnosticCodes()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? output.fileHandleForReading.close()
                readers.leave()
            }
            while let data = try? readChunk(from: output.fileHandleForReading), !data.isEmpty { records.append(data) }
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? errors.fileHandleForReading.close()
                readers.leave()
            }
            // Retain only protocol/error codes, never raw library output or filenames.
            while let data = try? readChunk(from: errors.fileHandleForReading), !data.isEmpty {
                diagnostics.append(data)
            }
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        let state = MTPExecutionState()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler {
            guard child.isRunning,
                cancellation?.isCancelled == true || ProcessInfo.processInfo.systemUptime >= deadline,
                state.stop()
            else { return }
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        child.waitUntilExit()
        timer.cancel()
        readers.wait()
        if !diagnostics.summary.isEmpty {
            let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
            TabDiagnostics.recordTransport(
                "mtp.library",
                detail: "op=\(request?["op"] as? String ?? "external") codes=\(diagnostics.summary)")
        }
        if cancellation?.isCancelled == true { throw CancellationError() }
        if state.stopped { throw MTPError.timeout }
        guard let response = records.response else { throw MTPError.protocolError }
        return response
    }
}

/// Extract a small whitelist from libmtp/libusb stderr. Chunk boundaries may split
/// an error code; keeping a short tail handles that without storing personal paths.
final class MTPDiagnosticCodes: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    private var codes = Set<String>()
    private static let patterns: [(String, NSRegularExpression)] = [
        (
            "ptp",
            try! NSRegularExpression(pattern: #"PTP (?:Layer )?error\s+([0-9a-f]{4})\b"#, options: .caseInsensitive)
        ),
        ("claim", try! NSRegularExpression(pattern: #"libusb_claim_interface\(\)\s*=\s*(-?[0-9]{1,5})"#)),
        ("session", try! NSRegularExpression(pattern: #"Could not open session!\s*\(Return code ([0-9]{1,5})\)"#)),
    ]

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        var chunk = tail
        chunk.append(data)
        tail = Data(chunk.suffix(256))
        let text = String(decoding: chunk, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        for (prefix, regex) in Self.patterns {
            for match in regex.matches(in: text, range: range) where codes.count < 16 {
                guard let value = Range(match.range(at: 1), in: text) else { continue }
                codes.insert(prefix + ":" + text[value].uppercased())
            }
        }
        if text.contains("libusb_claim_interface() reports device is busy") { codes.insert("usbBusy") }
        if text.contains("libusb_open() failed") { codes.insert("usbOpenFailed") }
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return codes.sorted().joined(separator: ",")
    }
}

private final class MTPExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func stop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }

    var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class MTPRecords: @unchecked Sendable {
    private var partial = Data()
    private(set) var response: Data?
    private let onProgress: ((Double?) -> Void)?
    private var overflow = false
    init(onProgress: ((Double?) -> Void)? = nil) { self.onProgress = onProgress }
    func append(_ data: Data) {
        guard !overflow else { return }
        partial.append(data)
        // Explicit failure instead of interpreting truncated JSON as a valid directory.
        guard partial.count <= 64 * 1024 * 1024 else {
            overflow = true
            response = nil
            partial = Data()
            return
        }
        while let end = partial.firstIndex(of: 10) {
            let record = Data(partial[..<end])
            partial.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else { continue }
            if let progress = value["progress"] as? Double, progress.isFinite, (0...1).contains(progress) {
                onProgress?(progress)
            } else if value["result"] != nil || value["error"] != nil {
                response = record
            }
        }
    }
}
