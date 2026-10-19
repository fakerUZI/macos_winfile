// 安卓文件操作（基于 adb）
//
// 路径表示：安卓设备上的绝对路径（如 /sdcard/Download/a.txt）。
// 在应用内部用 android://<serial>/<path> 作为虚拟地址，便于与本地 URL 区分。
import Foundation

/// 安卓虚拟地址
enum AndroidURL {
    static let scheme = "android"

    /// 构造虚拟 URL。
    ///
    /// 不用 URLComponents：它会把 host 规范化为小写，
    /// 而 adb 序列号区分大小写（如 HA2B7QSF），转小写会导致设备匹配失败。
    /// 这里直接拼字符串，读取时手工拆解。
    static func make(serial: String, path: String) -> URL {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        // 路径中可能含空格等字符，按 URL 规则转义；序列号本身是安全字符
        let encoded = normalized.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed) ?? normalized
        return URL(string: "\(scheme)://\(serial)\(encoded)")
            ?? URL(fileURLWithPath: normalized)
    }

    /// Every breadcrumb stays on the same device, including its root.
    static func ancestors(_ url: URL) -> [URL] {
        guard let (serial, path) = split(url) else { return [] }
        var result = [make(serial: serial, path: "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append(make(serial: serial, path: current))
        }
        return result
    }

    /// 是否为安卓地址
    static func isAndroid(_ url: URL) -> Bool { url.scheme == scheme }

    /// 取出序列号与路径（与 make 对称，不依赖 URL 的 host 解析）
    static func split(_ url: URL) -> (serial: String, path: String)? {
        guard isAndroid(url) else { return nil }
        let text = url.absoluteString
        guard let range = text.range(of: "\(scheme)://") else { return nil }
        let rest = text[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let serial = String(rest[rest.startIndex..<slash])
        let path = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
        guard !serial.isEmpty else { return nil }
        return (serial, path)
    }
}

final class AndroidFileService: @unchecked Sendable {

    /// 安卓上常见的存储根目录。
    /// 优先规范路径：`/sdcard` 是符号链接，直接使用会让 `ls -la` 列出链接本身
    /// 而非目录内容，造成"目录里看不到自己刚建的文件"这类问题。
    static let candidateRoots = [
        "/storage/emulated/0",
        "/storage/self/primary",
        "/sdcard",
    ]

    private let serial: String

    init(serial: String) {
        self.serial = serial
    }

    // MARK: - 基础命令

    /// 在设备上执行 shell 命令
    @discardableResult
    func shell(_ command: String, timeout: TimeInterval = 20) throws -> AdbResult {
        try AdbRunner.runChecked(["-s", serial, "shell", command], timeout: timeout)
    }

    /// 查询可用存储根
    func resolveRoot() -> String {
        for root in Self.candidateRoots {
            if let result = try? AdbRunner.run(["-s", serial, "shell", "ls", "-d", root], timeout: 8),
               result.ok {
                return root
            }
        }
        return "/sdcard"
    }

    // MARK: - 列目录

    /// 列出目录内容。
    ///
    /// 用 `ls -la` 解析：安卓的 toybox ls 输出格式稳定，
    /// 比反复调用 stat 快得多（一次进程调用列出整个目录）。
    func list(_ path: String) throws -> [AndroidEntry] {
        let result = try AdbRunner.run(["-s", serial, "shell", "ls", "-la", shellQuote(path)], timeout: 25)
        guard result.ok || !result.stdout.isEmpty else {
            throw AdbError.failed(result.stderr.isEmpty ? "无法读取目录" : result.stderr, result.exitCode)
        }
        return AndroidEntry.parseListOutput(result.stdout, parent: path, serial: serial)
    }

    /// 读取单个路径的信息
    func stat(_ path: String) throws -> AndroidEntry? {
        let result = try AdbRunner.run(["-s", serial, "shell", "ls", "-lad", shellQuote(path)], timeout: 15)
        guard result.ok else { return nil }
        return AndroidEntry.parseListOutput(result.stdout,
                                            parent: (path as NSString).deletingLastPathComponent,
                                            serial: serial).first
    }

    // MARK: - 读写

    /// 从设备复制到本地（带进度）
    func pull(remote: String, to local: URL,
              onProgress: ((Double?) -> Void)? = nil) throws {
        let result = try AdbRunner.runWithProgress(
            ["-s", serial, "pull", remote, local.path], onProgress: { onProgress?($0) })
        guard result.ok else {
            throw AdbError.failed(result.stderr.isEmpty ? result.stdout : result.stderr, result.exitCode)
        }
    }

    /// 从本地上传到设备（带进度）
    func push(local: URL, to remoteDirectory: String,
              onProgress: ((Double?) -> Void)? = nil) throws {
        let result = try AdbRunner.runWithProgress(
            ["-s", serial, "push", local.path, remoteDirectory], onProgress: { onProgress?($0) })
        guard result.ok else {
            throw AdbError.failed(result.stderr.isEmpty ? result.stdout : result.stderr, result.exitCode)
        }
    }

    /// 递归统计目录大小与文件数（用于传输前的规模提示）
    func directoryStats(_ path: String) -> (bytes: Int64, files: Int)? {
        guard let result = try? AdbRunner.run(
            ["-s", serial, "shell", "du", "-s", "-k", shellQuote(path)], timeout: 60) else { return nil }
        let numbers = result.stdout.split(separator: " ").compactMap { Int64($0) }
        guard let kilobytes = numbers.first else { return nil }
        guard let countResult = try? AdbRunner.run(
            ["-s", serial, "shell", "find", shellQuote(path), "-type", "f"], timeout: 120) else {
            return (kilobytes * 1024, 0)
        }
        let files = countResult.stdout.split(separator: "\n").count
        return (kilobytes * 1024, files)
    }

    // MARK: - 修改

    func createFolder(at path: String) throws {
        try shell("mkdir -p \(shellQuote(path))")
    }

    func createEmptyFile(at path: String) throws {
        try shell("touch \(shellQuote(path))")
    }

    func rename(_ path: String, to newName: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try shell("mv \(shellQuote(path)) \(shellQuote(parent + "/" + newName))")
    }

    func move(_ path: String, to directory: String) throws {
        try shell("mv \(shellQuote(path)) \(shellQuote(directory))")
    }

    /// 复制到目标目录内。
    ///
    /// 说明：不用 `cp -rT`（安卓的 toybox 不支持该选项），
    /// 改为显式拼出目标完整路径，避免 `cp -r 源 目录` 的语义歧义
    /// （部分实现会把它理解成"复制成同名文件"）。
    func copy(_ path: String, to directory: String) throws {
        let name = (path as NSString).lastPathComponent
        let dir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        let target = dir + "/" + name
        // 注意：目标是否存在必须在**设备上**判断。
        // 用本地 FileManager 检查安卓路径永远返回 false，会导致把文件复制到自身。
        if self.exists(target) {
            // 目标已存在：加"副本"后缀直到不冲突，避免覆盖
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var index = 1
            var candidate = ext.isEmpty ? "\(base) 副本" : "\(base) 副本.\(ext)"
            while self.exists(dir + "/" + candidate) {
                index += 1
                candidate = ext.isEmpty ? "\(base) 副本 \(index)" : "\(base) 副本 \(index).\(ext)"
            }
            try shell("cp -r \(shellQuote(path)) \(shellQuote(dir + "/" + candidate))")
        } else {
            try shell("cp -r \(shellQuote(path)) \(shellQuote(target))")
        }
    }

    func remove(_ path: String) throws {
        try shell("rm -rf \(shellQuote(path))")
    }

    /// 判断设备上是否存在该路径
    func exists(_ path: String) -> Bool {
        guard let result = try? AdbRunner.run(
            ["-s", serial, "shell", "test", "-e", shellQuote(path)], timeout: 10) else { return false }
        return result.ok
    }

    // MARK: - 工具

    /// 单引号包裹并转义，防止路径中的空格/特殊字符破坏命令
    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
