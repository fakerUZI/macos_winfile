// 压缩与解压
//
// 实现说明（都是实测得出的）：
//   - 压缩用 /usr/bin/zip：默认写 UTF-8 文件名，中文不乱码
//     （ditto 写入的是历史编码，解压时中文名会乱码）
//   - 解压先解到临时目录、再逐项合并进目标：全程零覆盖 ——
//     目标已有同名项时改解到「<压缩包名> 解压」独立文件夹
//     （与 macOS 归档实用工具行为一致），绝不静默覆盖用户文件
//   - zip 走 ditto -x -k（还原元数据）；tar 系走 bsdtar（系统自带，
//     自动识别 gzip/bzip2/xz 压缩方式）
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
    /// zip 用 ditto 解压；tar/tgz/gz/bz2/xz 系用系统 bsdtar（自动识别压缩方式）
    static let archiveExtensions: Set<String> = [
        "zip",
        "tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "txz",
    ]

    /// 需要用 bsdtar 而非 ditto 解压的扩展名
    private static let tarExtensions: Set<String> = [
        "tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "txz",
    ]

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
    /// 流程：先解到临时目录，再逐项移入目标 ——
    /// - 目标已存在同名项时**绝不覆盖**，而是整体改解到
    ///   「<压缩包名> 解压」文件夹（必要时加序号），与归档实用工具一致
    /// - 自动跳过 __MACOSX 元数据目录
    ///
    /// - Returns: 解压产生的顶层项目（便于解压后选中它们）
    @discardableResult
    static func extract(_ archive: URL, to destination: URL) throws -> [URL] {
        guard isArchive(archive) else {
            throw ArchiveError.commandFailed(L("archive.error.unsupported", "暂不支持该格式"), -1)
        }
        let fm = FileManager.default

        // 1) 先解到临时目录（与目标隔离，之后按自己的规则合并）
        let staging = fm.temporaryDirectory
            .appendingPathComponent("winfile-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        if tarExtensions.contains(archive.pathExtension.lowercased()) {
            try runTar(["-xf", archive.path, "-C", staging.path])
        } else {
            // ditto -x -k：解压 zip 并还原元数据
            try runDitto(["-x", "-k", archive.path, staging.path])
        }

        // 2) 顶层项目（过滤 __MACOSX 元数据目录）
        let topNames = ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? [])
            .filter { $0 != "__MACOSX" }
            .sorted()

        // 3) 冲突检测：临时目录树中任一项目在目标下已存在即为冲突
        //    （目录重名也算 —— moveItem 无法合并进已有目录，重名会失败）
        let targetDir: URL
        if !topNames.isEmpty && hasConflicts(staging: staging, destination: destination) {
            targetDir = uniqueExtractFolder(in: destination,
                                            baseName: archive.deletingPathExtension().lastPathComponent)
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } else {
            targetDir = destination
        }

        // 4) 逐项移入目标
        var created: [URL] = []
        for name in topNames {
            let source = staging.appendingPathComponent(name)
            let target = targetDir.appendingPathComponent(name)
            try fm.moveItem(at: source, to: target)
            created.append(target)
        }
        return created
    }

    /// 临时目录树中是否存在与目标目录冲突的路径
    private static func hasConflicts(staging: URL, destination: URL) -> Bool {
        let fm = FileManager.default
        /// 收集目录树的全部相对路径（跳过 __MACOSX）
        func relativePaths(_ directory: URL, prefix: String) -> [String] {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
            var result: [String] = []
            for name in names {
                guard name != "__MACOSX" else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let absolute = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: absolute.path, isDirectory: &isDirectory)
                result.append(relative)
                if isDirectory.boolValue {
                    result.append(contentsOf: relativePaths(absolute, prefix: relative))
                }
            }
            return result
        }
        return relativePaths(staging, prefix: "").contains { relative in
            fm.fileExists(atPath: destination.appendingPathComponent(relative).path)
        }
    }

    /// 「名称 解压」「名称 解压 2」…
    static func uniqueExtractFolder(in directory: URL, baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName) 解压")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) 解压 \(index)")
            index += 1
        }
        return candidate
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

    @discardableResult
    private static func runTar(_ arguments: [String]) throws -> ProcessResult {
        try run("/usr/bin/tar", arguments)
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
