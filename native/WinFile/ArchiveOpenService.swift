import AppKit
import CryptoKit
import Foundation

enum ArchiveOpenError: LocalizedError {
    case extractFirst, link, noApplication, failed

    var errorDescription: String? {
        switch self {
        case .extractFirst: return L("archive.open.extractFirst", "仅支持直接打开小于 64 MiB 的文件。此文件达到大小限制或大小未知，请先解压再打开。")
        case .link: return L("archive.open.link", "不直接打开压缩包中的链接，请先解压并确认目标。")
        case .noApplication: return L("archive.open.noApplication", "未找到可打开此文件的默认应用，请设置打开方式，或先解压后打开。")
        case .failed: return L("archive.open.failed", "默认应用未能打开文件，请先解压后重试。")
        }
    }
}

/// Files handed to external apps must outlive the archive sheet and its Quick Look workspace.
/// Repeated opens in one archive session reuse a read-only copy. Older sessions are reclaimed
/// after seven days or above the 512 MiB target; this process never evicts its own handed-off files.
final class ArchiveOpenService: @unchecked Sendable {
    static let shared = ArchiveOpenService()
    private let root: URL
    private let budget: Int64
    private let lifetime: TimeInterval
    private let lock = NSLock()
    private var cachedURLs: [String: URL] = [:]

    init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.winfile.mac/ArchiveOpen", isDirectory: true),
         budget: Int64 = 512 * 1024 * 1024, lifetime: TimeInterval = 7 * 86400) {
        self.root = root
        self.budget = max(0, budget)
        self.lifetime = max(0, lifetime)
    }

    func prepare(_ member: ArchiveMember, contents: ArchiveContents, password: String? = nil,
                 cancellation: ScanCancellation = ScanCancellation()) throws -> URL {
        guard !member.isLink else { throw ArchiveOpenError.link }
        guard member.canOpenExternally, let size = member.size else { throw ArchiveOpenError.extractFirst }
        lock.lock()
        defer { lock.unlock() }
        try ArchiveService.checkCancellation(cancellation)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ArchiveError.unsafePath }
        // The session workspace isolates passwords and multipart archive snapshots as well as paths.
        let identity = try JSONEncoder().encode([contents.workspace.path, member.path])
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent(key, isDirectory: true)
        if let target = cachedURLs[key], valid(target, folder: folder, size: size) {
            try ArchiveService.validateMember(member, contents: contents, password: password, cancellation: cancellation)
            try ArchiveService.checkCancellation(cancellation)
            return target
        }
        if cachedURLs.removeValue(forKey: key) != nil { ArchiveService.removeStaging(folder) }
        prune()
        let prepared = try ArchiveService.prepareMemberPreview(member, contents: contents, password: password, cancellation: cancellation)
        defer { prepared.close() }
        let values = try prepared.url.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? Int.max) < ArchiveService.memberPreviewLimit else { throw ArchiveOpenError.extractFirst }
        try ArchiveService.checkCancellation(cancellation)
        // Move the validated tree, retaining its basename/extension for Launch Services associations.
        if fm.fileExists(atPath: folder.path) { throw ArchiveError.invalidListing }
        try fm.moveItem(at: prepared.directory, to: folder)
        let relative = String(prepared.url.path.dropFirst(prepared.directory.path.count + 1))
        let opened = folder.appendingPathComponent(relative)
        do {
            try ArchiveService.checkCancellation(cancellation)
            cachedURLs[key] = opened
            return opened
        } catch {
            ArchiveService.removeStaging(folder)
            throw error
        }
    }

    private func valid(_ url: URL, folder: URL, size: Int64) -> Bool {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return false }
        // Reject symlinked ancestors too, even if the leaf is a regular file.
        var parent = url.deletingLastPathComponent()
        while parent.path != folder.path {
            guard parent.path.hasPrefix(folder.path + "/"),
                  (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false else { return false }
            parent.deleteLastPathComponent()
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return Int64(values.fileSize ?? -1) == size
    }

    /// Called under the lock on a worker, never on the UI thread.
    private func prune() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? []
        var candidates: [(URL, Date, Int64)] = []
        var total: Int64 = 0
        for folder in folders {
            let name = folder.lastPathComponent
            guard name.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            var size: Int64 = 0
            if let tree = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) {
                for case let file as URL in tree {
                    let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                    if values?.isSymbolicLink == true { tree.skipDescendants() }
                    else { size += Int64(values?.fileSize ?? 0) }
                }
            }
            total += size
            if cachedURLs[name] == nil { candidates.append((folder, values.contentModificationDate ?? .distantPast, size)) }
        }
        for (folder, date, size) in candidates.sorted(by: { $0.1 < $1.1 }) {
            if total > budget || Date().timeIntervalSince(date) > lifetime {
                if (try? fm.removeItem(at: folder)) != nil { total -= size }
            }
        }
    }

    @MainActor
    static func application(for url: URL) -> URL? {
        FileAssociations.shared.application(for: url) ?? NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    @MainActor
    static func openDefault(_ url: URL) async throws {
        guard let app = application(for: url) else { throw ArchiveOpenError.noApplication }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { runningApp, error in
                if let error { continuation.resume(throwing: error) }
                else if runningApp != nil { continuation.resume() }
                else { continuation.resume(throwing: ArchiveOpenError.failed) }
            }
        }
    }
}
