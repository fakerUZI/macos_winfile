// 安卓文件操作（基于 adb）
//
// 路径表示：安卓设备上的绝对路径（如 /sdcard/Download/a.txt）。
// 在应用内部用 android://<serial>/<path> 作为虚拟地址，便于与本地 URL 区分。
import Foundation

/// 安卓虚拟地址
enum AndroidURL {
    static let scheme = "android"

    /// 构造虚拟 URL
    static func make(serial: String, path: String) -> URL {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents()
        components.scheme = scheme
        components.host = serial
        components.path = normalized
        return components.url ?? URL(string: "\(scheme)://\(serial)\(normalized)")!
    }

    /// 是否为安卓地址
    static func isAndroid(_ url: URL) -> Bool { url.scheme == scheme }

    /// 取出序列号与路径
    static func split(_ url: URL) -> (serial: String, path: String)? {
        guard isAndroid(url), let serial = url.host else { return nil }
        return (serial, url.path)
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
        return AndroidEntry.parseListOutput(result.stdout, parent: path)
    }

    /// 读取单个路径的信息
    func stat(_ path: String) throws -> AndroidEntry? {
        let result = try AdbRunner.run(["-s", serial, "shell", "ls", "-lad", shellQuote(path)], timeout: 15)
        guard result.ok else { return nil }
        return AndroidEntry.parseListOutput(result.stdout, parent: (path as NSString).deletingLastPathComponent).first
    }

    // MARK: - 读写

    /// 从设备复制到本地
    func pull(remote: String, to local: URL) throws {
        try AdbRunner.runChecked(["-s", serial, "pull", remote, local.path], timeout: 600)
    }

    /// 从本地上传到设备
    func push(local: URL, to remoteDirectory: String) throws {
        try AdbRunner.runChecked(["-s", serial, "push", local.path, remoteDirectory], timeout: 600)
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
            // 目标已存在：加上"副本"后缀，避免覆盖
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let unique = ext.isEmpty ? "\(base) 副本" : "\(base) 副本.\(ext)"
            try shell("cp -r \(shellQuote(path)) \(shellQuote(dir + "/" + unique))")
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
