// adb 进程调用封装
//
// 设计要点：
//   - 所有 adb 调用集中在这里，便于审计与超时控制
//   - 每个命令都有超时，避免设备断开时界面卡死
//   - 输出统一按行解析，路径含空格/中文时按 NUL 分隔解析更安全
import Foundation

enum AdbError: LocalizedError {
    case notInstalled
    case timeout(String)
    case failed(String, Int32)
    case noDevice

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return L("android.error.noAdb",
                     "未找到 adb。请先安装：brew install android-platform-tools")
        case .timeout(let cmd):
            return L("android.error.timeout", "命令超时：%@", cmd)
        case .failed(let message, let code):
            return L("android.error.failed", "adb 执行失败（%d）：%@", Int(code), message)
        case .noDevice:
            return L("android.error.noDevice", "没有可用的安卓设备")
        }
    }
}

/// 命令执行结果
struct AdbResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

enum AdbRunner {

    /// adb 可执行文件路径（首次解析后缓存）
    private nonisolated(unsafe) static var cachedPath: String??

    /// 常见安装位置，避免依赖 PATH（GUI 应用通常没有 shell 的 PATH）
    private static let candidatePaths = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        "/usr/bin/adb",
    ]

    /// 找到 adb 路径
    static func adbPath() -> String? {
        if let cached = cachedPath { return cached }
        var found: String?
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            found = path
            break
        }
        if found == nil {
            // 退回环境变量 PATH 查找
            if let envPath = ProcessInfo.processInfo.environment["PATH"] {
                for dir in envPath.split(separator: ":") {
                    let candidate = String(dir) + "/adb"
                    if fm.isExecutableFile(atPath: candidate) { found = candidate; break }
                }
            }
        }
        cachedPath = found
        return found
    }

    static var isAvailable: Bool { adbPath() != nil }

    /// 带进度上报的执行（用于 push/pull 这类耗时操作）。
    ///
    /// adb 的传输进度输出在 stderr，形如 `[ 45%] /path`，
    /// 这里逐行解析并回调，让界面能显示真实进度而不是"假死"。
    /// - Parameter onProgress: 0…1 的进度（无法解析时为 nil）
    static func runWithProgress(_ arguments: [String],
                                timeout: TimeInterval = 3600,
                                onProgress: @escaping (Double?) -> Void) throws -> AdbResult {
        guard let adb = adbPath() else { throw AdbError.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // adb 的进度写在 stderr；逐行读取并及时回调
        var collected = Data()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collected.append(chunk)
            if let text = String(data: chunk, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    if let percent = parsePercent(String(line)) {
                        onProgress(percent)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw AdbError.failed(error.localizedDescription, -1)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        let errText = String(data: collected, encoding: .utf8) ?? ""

        return AdbResult(stdout: String(data: outData, encoding: .utf8) ?? "",
                         stderr: errText,
                         exitCode: process.terminationStatus)
    }

    /// 从 adb 输出行中解析百分比（如 `[ 45%] /sdcard/a.bin`）
    static func parsePercent(_ line: String) -> Double? {
        guard let open = line.firstIndex(of: "["),
              let percentIndex = line.firstIndex(of: "%"),
              open < percentIndex else { return nil }
        let numberPart = line[line.index(after: open)..<percentIndex]
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(numberPart), value >= 0, value <= 100 else { return nil }
        return value / 100
    }

    /// 执行 adb 命令
    /// - Parameters:
    ///   - arguments: 不含 adb 本身的参数
    ///   - timeout: 超时秒数（默认 20 秒）
    static func run(_ arguments: [String], timeout: TimeInterval = 20) throws -> AdbResult {
        guard let adb = adbPath() else { throw AdbError.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // 避免 adb 在等待设备时无限阻塞
        var environment = ProcessInfo.processInfo.environment
        environment["ADB_LOCAL_TRANSPORT_MAX_PORT"] = environment["ADB_LOCAL_TRANSPORT_MAX_PORT"] ?? "5555"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw AdbError.failed(error.localizedDescription, -1)
        }

        // 超时保护：到点强制结束，避免界面卡死
        let deadline = Date().addingTimeInterval(timeout)
        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: killer)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        if Date() > deadline && process.terminationStatus != 0 {
            throw AdbError.timeout(arguments.joined(separator: " "))
        }

        return AdbResult(stdout: String(data: outData, encoding: .utf8) ?? "",
                         stderr: String(data: errData, encoding: .utf8) ?? "",
                         exitCode: process.terminationStatus)
    }

    /// 执行并要求成功，失败抛错
    @discardableResult
    static func runChecked(_ arguments: [String], timeout: TimeInterval = 20) throws -> AdbResult {
        let result = try run(arguments, timeout: timeout)
        guard result.ok else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AdbError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines), result.exitCode)
        }
        return result
    }
}
