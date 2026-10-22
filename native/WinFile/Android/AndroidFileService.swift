// Android virtual URLs and the single MTP file service.
import Foundation

/// 安卓虚拟地址
enum AndroidURL {
    static let scheme = "android"

    /// Directory URLs may acquire a trailing slash after navigating to their parent.
    /// Keep path components unchanged (including dots), but remove empty separators.
    private static func normalizedPath(_ path: String) -> String {
        "/" + path.split(separator: "/").joined(separator: "/")
    }

    /// 构造虚拟 URL。
    ///
    /// 不用 URLComponents：它会把 host 规范化为小写，
    /// 而设备序列号区分大小写（如 HA2B7QSF），转小写会导致设备匹配失败。
    /// 这里直接拼字符串，读取时手工拆解。
    static func make(serial: String, path: String) -> URL {
        let normalized = normalizedPath(path)
        // 路径中可能含空格等字符，按 URL 规则转义；序列号本身是安全字符
        let encoded =
            normalized.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#")))
            ?? normalized
        let device =
            serial.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        return URL(string: "\(scheme)://\(device)\(encoded)")!
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
        let serial = String(rest[rest.startIndex..<slash]).removingPercentEncoding ?? ""
        let path = normalizedPath(String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...]))
        guard !serial.isEmpty else { return nil }
        return (serial, path)
    }
}

final class AndroidFileService: @unchecked Sendable {
    private let serial: String
    init(serial: String) { self.serial = serial }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    func list(_ path: String) throws -> [AndroidEntry] {
        try (MTPRunner.run("list", serial: serial, path: path).entries ?? []).map { try $0.entry(serial: serial) }
    }

    func stat(_ path: String) throws -> AndroidEntry? {
        do {
            return try MTPRunner.run("stat", serial: serial, path: path).entry?.entry(serial: serial)
        } catch MTPError.operation("notFound") { return nil }
    }

    func fileRevision(_ path: String) throws -> AndroidFileRevision {
        guard let entry = try stat(path), !entry.isDirectory else { throw AndroidOpenError.invalidFile }
        return AndroidFileRevision(
            size: entry.size, modified: Int64(entry.modified?.timeIntervalSince1970 ?? 0),
            identity: "\(MTPRunner.attachmentID(serial: serial)):\(entry.storageID):\(entry.objectID)")
    }

    func pull(
        remote: String, to local: URL, cancellation: ScanCancellation? = nil,
        onProgress: ((Double?) -> Void)? = nil
    ) throws {
        guard let source = try stat(remote) else { throw MTPError.operation("notFound") }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: local.path, isDirectory: &isDirectory)
        let target = exists && isDirectory.boolValue ? local.appendingPathComponent(source.name) : local
        guard !fm.fileExists(atPath: target.path),
            (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw MTPError.operation("exists") }
        let work = target.deletingLastPathComponent().appendingPathComponent(
            ".winfile-mtp-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("payload", isDirectory: source.isDirectory)
        _ = try MTPRunner.run(
            "pull", serial: serial, path: remote, values: ["local": payload.path], cancellation: cancellation,
            progress: onProgress)
        if cancellation?.isCancelled == true { throw CancellationError() }
        if !source.isDirectory {
            guard let after = try stat(remote),
                after.objectID == source.objectID && after.size == source.size && after.modified == source.modified
            else { throw AndroidOpenError.changed }
        }
        try fm.moveItem(at: payload, to: target)
    }

    func push(
        local: URL, to remoteDirectory: String, cancellation: ScanCancellation? = nil,
        onProgress: ((Double?) -> Void)? = nil
    ) throws {
        _ = try MTPRunner.run(
            "push", serial: serial, path: remoteDirectory, values: ["local": local.path], cancellation: cancellation,
            progress: onProgress)
    }

    func createFolder(at path: String) throws { _ = try MTPRunner.run("mkdir", serial: serial, path: path) }
    func createEmptyFile(at path: String) throws { _ = try MTPRunner.run("touch", serial: serial, path: path) }
    func rename(_ path: String, to newName: String) throws {
        guard Self.validName(newName) else { throw MTPError.operation("invalidName") }
        if (path as NSString).lastPathComponent == newName { return }
        _ = try MTPRunner.run("rename", serial: serial, path: path, values: ["name": newName])
    }

    func move(_ path: String, to directory: String) throws {
        if (path as NSString).deletingLastPathComponent == directory { return }
        _ = try MTPRunner.run("move", serial: serial, path: path, values: ["target": directory])
    }
    /// Many phones do not implement CopyObject. Copy verified bytes through MTP in both directions.
    /// The original is always retained; upload refuses to overwrite another object.
    func copy(_ path: String, to directory: String, cancellation: ScanCancellation? = nil) throws {
        guard let source = try stat(path) else { throw MTPError.operation("notFound") }
        guard directory != path && !directory.hasPrefix(path + "/") else { throw MTPError.operation("recursive") }
        let names = Set(try list(directory).map(\.name))
        let name = source.name
        var candidate = name
        var index = 1
        while names.contains(candidate) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = base + (index == 1 ? " Copy" : " Copy \(index)") + (ext.isEmpty ? "" : "." + ext)
            index += 1
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("WinFile-MTP-Copy-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let local = work.appendingPathComponent(candidate)
        try pull(remote: path, to: local, cancellation: cancellation)
        try push(local: local, to: directory, cancellation: cancellation)
    }

    func remove(_ path: String) throws { _ = try MTPRunner.run("delete", serial: serial, path: path) }
}
