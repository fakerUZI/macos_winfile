// 压缩与解压
//
// 实现说明（都是实测得出的）：
//   - 压缩用 /usr/bin/zip：默认写 UTF-8 文件名，中文不乱码
//     （ditto 写入的是历史编码，解压时中文名会乱码）
//   - 解压先解到临时目录、再逐项合并进目标：全程零覆盖 ——
//     目标已有同名项时改解到「<压缩包名> 解压」独立文件夹
//     （与 macOS 归档实用工具行为一致），绝不静默覆盖用户文件
//   - 解压使用内置 7-Zip；普通 ZIP 使用 ditto 还原 macOS 元数据。
//   - 私有暂存、子进程写入隔离、路径检查与取消由 ArchiveExtraction 实现。
import Foundation

enum ArchiveError: LocalizedError {
    case unsupported, engineMissing, passwordRequired, wrongPassword, cancelled, unsafePath, insufficientSpace
    case missingVolume(String)
    case noSelection
    case commandFailed(String, Int32)
    case alreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .unsupported: return L("archive.error.unsupported", "暂不支持该格式")
        case .engineMissing: return L("archive.error.engineMissing", "解压引擎缺失，请重新安装 WinFile。")
        case .passwordRequired: return L("archive.error.passwordRequired", "此压缩包需要密码。")
        case .wrongPassword: return L("archive.error.wrongPassword", "密码错误或加密数据损坏，请检查后重试。")
        case .cancelled: return L("archive.cancelled", "已取消解压")
        case .unsafePath: return L("archive.error.unsafePath", "压缩包包含不安全的路径或外部链接，已停止解压。")
        case .insufficientSpace: return L("archive.error.space", "目标磁盘的可用空间不足。")
        case .missingVolume(let name): return L("archive.error.volume", "分卷不完整或压缩包已截断。请将所有分卷放在同一文件夹后重试。%@", name.isEmpty ? "" : "\n" + name)

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
    var fraction: Double? = nil
    var index = 1
    var total = 1
    var title: String {
        isCompressing
            ? L("archive.compressing", "正在压缩 %@", name)
            : L("archive.extracting", "正在解压 %@", name)
    }
}

enum ArchiveService {

    /// 可识别的压缩包扩展名
    /// 由内置 7-Zip 解码，普通 ZIP 保留 ditto 元数据处理。
    static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z",
        "tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "txz",
    ]

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
            || url.lastPathComponent.range(of: #"\.(?:7z|zip)\.[0-9]{3,}$|\.[rz][0-9]{2,3}$"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
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
            var groups: [String: URL] = [:]
            var names: [String] = []
            var seen = Set<String>()
            for url in urls where seen.insert(FileItem.canonicalID(for: url)).inserted {
                let parent = url.deletingLastPathComponent()
                let key = parent.standardizedFileURL.resolvingSymlinksInPath().path
                let group: URL
                if let existing = groups[key] { group = existing }
                else {
                    group = FSEngine.uniqueURL(in: staging, name: parent.lastPathComponent.isEmpty ? "Files" : parent.lastPathComponent, isDirectory: true)
                    try fm.createDirectory(at: group, withIntermediateDirectories: false)
                    groups[key] = group
                    names.append(group.lastPathComponent)
                }
                try fm.copyItem(at: url, to: group.appendingPathComponent(url.lastPathComponent))
            }
            try runZip(at: staging, names: names, target: target)
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

    /// 「名称 解压」「名称 解压 2」…
    static func uniqueExtractFolder(in directory: URL, baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName) 解压")
        var index = 2
        while (try? fm.attributesOfItem(atPath: candidate.path)) != nil {
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
        while (try? fm.attributesOfItem(atPath: candidate.path)) != nil {
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

}
