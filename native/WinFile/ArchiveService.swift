// 压缩与解压
//
// 实现说明：macOS 自带 ditto / unzip，无需第三方库。
//   - 压缩用 ditto：保留资源分支与扩展属性（zip 命令会丢失，导致
//     解压后别名、标签等信息消失）
//   - 解压用 ditto -x -k：同样保留元数据
// 与安卓功能不同，这里不依赖任何外部安装，属于系统自带工具。
import Foundation

enum ArchiveError: LocalizedError {
    case noSelection
    case commandFailed(String, Int32)
    case alreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return L("archive.error.noSelection", "请先选择要压缩的项目")
        case .commandFailed(let message, let code):
            return L("archive.error.failed", "操作失败（%d）：%@", Int(code), message)
        case .alreadyExists(let url):
            return L("archive.error.exists", "目标已存在：%@", url.lastPathComponent)
        }
    }
}

/// 压缩进度（大目录时用于界面提示）
struct ArchiveProgress: Equatable {
    let name: String
    let isCompressing: Bool
    var title: String {
        isCompressing
            ? L("archive.compressing", "正在压缩 %@", name)
            : L("archive.extracting", "正在解压 %@", name)
    }
}

enum ArchiveService {

    /// 可识别的压缩包扩展名
    static let archiveExtensions: Set<String> = ["zip"]

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// 压缩若干项目到目标位置。
    ///
    /// 实现要点（都是实测得出的）：
    ///   1. 用 `/usr/bin/zip` 而非 ditto：ditto 写入的文件名是历史编码，
    ///      解压时中文名会乱码；zip 默认写 UTF-8。
    ///   2. **以父目录为工作目录**、用项目名作为入参：这样压缩包内保留顶层目录，
    ///      解压后不会把内容铺平（否则「压缩文件夹」再解压会散落一地）。
    ///   3. `-y` 保留符号链接本身（而不是跟随成实体文件）。
    ///
    /// - Parameters:
    ///   - urls: 要压缩的文件/文件夹（可多个，需在同一父目录下）
    ///   - destination: 压缩包输出目录
    ///   - name: 压缩包文件名（不含扩展名）
    /// - Returns: 生成的压缩包 URL
    @discardableResult
    static func compress(_ urls: [URL], to destination: URL, name: String) throws -> URL {
        guard !urls.isEmpty else { throw ArchiveError.noSelection }

        let target = uniqueArchiveURL(in: destination, baseName: name)
        let fm = FileManager.default

        // 全部项目应位于同一父目录，才能用相对名一次打包
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard parents.count == 1, let workingDirectory = urls.first?.deletingLastPathComponent() else {
            // 来自不同目录：先汇集到临时目录再打包
            let staging = fm.temporaryDirectory
                .appendingPathComponent("winfile-archive-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            for url in urls {
                try fm.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
            }
            try runZip(at: staging, names: urls.map(\.lastPathComponent), target: target)
            return target
        }

        try runZip(at: workingDirectory, names: urls.map(\.lastPathComponent), target: target)
        return target
    }

    /// 以 base 为工作目录执行 zip
    private static func runZip(at base: URL, names: [String], target: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r 递归；-y 保留符号链接；-q 安静模式
        process.arguments = ["-r", "-y", "-q", target.path] + names
        process.currentDirectoryURL = base

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ArchiveError.commandFailed(
                L("archive.error.zipFailed", "打包失败（退出码 %d）", Int(process.terminationStatus)),
                process.terminationStatus)
        }
    }

    /// 解压压缩包到目标目录。
    ///
    /// - Returns: 解压产生的顶层项目（便于解压后选中它们）
    @discardableResult
    static func extract(_ archive: URL, to destination: URL) throws -> [URL] {
        guard isArchive(archive) else {
            throw ArchiveError.commandFailed(L("archive.error.unsupported", "暂不支持该格式"), -1)
        }
        let before = Set((try? FileManager.default.contentsOfDirectory(
            atPath: destination.path)) ?? [])

        // ditto -x -k：解压 zip 并还原元数据
        try runDitto(["-x", "-k", archive.path, destination.path])

        let after = Set((try? FileManager.default.contentsOfDirectory(
            atPath: destination.path)) ?? [])
        let created = after.subtracting(before).sorted()
        return created.map { destination.appendingPathComponent($0) }
    }

    /// 解压后顶层项目的名称（用于确认压缩包结构）。
    ///
    /// 说明：不用 `unzip -Z1` 列出内容 —— macOS 自带的 Info-ZIP 6.00 对
    /// 非 ASCII 文件名会显示为 `???`（实测确认，与压缩包本身无关）。
    /// 这里改为解压到临时目录再枚举，得到的是真实名称。
    static func topLevelNames(of archive: URL) -> [String] {
        let fm = FileManager.default
        let probe = fm.temporaryDirectory
            .appendingPathComponent("winfile-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: probe) }
        do {
            try fm.createDirectory(at: probe, withIntermediateDirectories: true)
            _ = try extract(archive, to: probe)
            let names = (try? fm.contentsOfDirectory(atPath: probe.path)) ?? []
            return names.filter { $0 != "__MACOSX" }.sorted()
        } catch {
            return []
        }
    }

    // MARK: - 工具

    /// 生成不冲突的压缩包名（已存在时追加序号）
    static func uniqueArchiveURL(in directory: URL, baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).zip")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(index).zip")
            index += 1
        }
        return candidate
    }

    /// 为一批项目推导默认压缩包名
    static func defaultArchiveName(for urls: [URL]) -> String {
        if urls.count == 1, let name = urls.first?.lastPathComponent {
            return (name as NSString).deletingPathExtension
        }
        return L("archive.defaultName", "归档")
    }

    @discardableResult
    private static func runDitto(_ arguments: [String]) throws -> ProcessResult {
        try run("/usr/bin/ditto", arguments)
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = ProcessResult(stdout: String(data: outData, encoding: .utf8) ?? "",
                                   stderr: String(data: errData, encoding: .utf8) ?? "",
                                   status: process.terminationStatus)
        guard result.status == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw ArchiveError.commandFailed(
                message.trimmingCharacters(in: .whitespacesAndNewlines), result.status)
        }
        return result
    }
}
