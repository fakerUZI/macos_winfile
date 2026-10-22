import CryptoKit
import Foundation

struct AndroidFileRevision: Equatable {
    let size: Int64
    let modified: Int64
    var identity: String = ""
}

enum AndroidOpenError: LocalizedError {
    case invalidFile, changed, incomplete, noSpace
    var errorDescription: String? {
        switch self {
        case .invalidFile: return L("android.open.invalid", "无法打开此安卓文件，请重新读取目录后重试。")
        case .changed: return L("android.open.changed", "设备上的文件在下载期间发生变化，请重试。")
        case .incomplete: return L("android.open.incomplete", "下载不完整，未打开文件。请检查设备连接后重试。")
        case .noSpace: return L("android.open.noSpace", "本机缓存所在磁盘的可用空间不足，无法下载此文件。")
        }
    }
}

/// Immutable local copies, never a writable mount: edits are not uploaded to the device.
final class AndroidOpenService: @unchecked Sendable {
    static let shared = AndroidOpenService()
    typealias Revision = (AndroidEntry) throws -> AndroidFileRevision
    typealias Download = (AndroidEntry, URL, ScanCancellation, @escaping (Double?) -> Void) throws -> Void
    private let root: URL
    private let revision: Revision
    private let download: Download
    private let lock = NSLock()
    private var protected = Set<String>()
    private let budget: Int64

    init(
        root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.winfile.mac/AndroidOpen", isDirectory: true),
        budget: Int64 = 2 * 1024 * 1024 * 1024,
        revision: @escaping Revision = { try AndroidFileService(serial: $0.serial).fileRevision($0.path) },
        download: @escaping Download = { entry, target, token, progress in
            try AndroidFileService(serial: entry.serial).pull(
                remote: entry.path, to: target,
                cancellation: token, onProgress: progress)
        }
    ) {
        self.root = root
        self.budget = max(0, budget)
        self.revision = revision
        self.download = download
    }

    static func valid(_ entry: AndroidEntry) -> Bool {
        !entry.isDirectory && !entry.serial.isEmpty && entry.path.hasPrefix("/")
            && !entry.path.contains("\0") && entry.name == (entry.path as NSString).lastPathComponent
            && !entry.name.isEmpty && entry.name != "." && entry.name != ".."
            && !entry.name.contains("/") && !entry.name.contains("\0")
    }

    /// Preview.app starts Image Capture's camera browser even for a local copy.
    /// That browser can exclusively claim the same USB interface used by MTP.
    /// Keep Android images and PDFs in Quick Look; local file associations stay unchanged.
    static func prefersInAppPreview(_ entry: AndroidEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        let category = FileTypeDB.info(
            name: entry.name, isDirectory: false, isSymlink: false, isBundle: false
        ).category
        return category == .image || category == .pdf
    }

    private func check(_ token: ScanCancellation) throws { if token.isCancelled { throw CancellationError() } }

    func prepare(
        _ entry: AndroidEntry, cancellation: ScanCancellation,
        progress: @escaping (Double?) -> Void = { _ in }
    ) throws -> URL {
        guard Self.valid(entry) else { throw AndroidOpenError.invalidFile }
        try check(cancellation)
        let before = try revision(entry)
        guard before.size >= 0 else { throw AndroidOpenError.invalidFile }
        try check(cancellation)
        let identity = try JSONEncoder().encode([
            entry.serial, entry.path, String(before.size), String(before.modified), before.identity,
            before.modified > 0 ? "" : UUID().uuidString,
        ])
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(key, isDirectory: true)
        let cached = directory.appendingPathComponent(entry.name)
        let fm = FileManager.default
        lock.lock()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw AndroidOpenError.invalidFile
            }
            prune()
            if validCached(cached, size: before.size) {
                protected.insert(key)
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
                lock.unlock()
                return cached
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        if let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
            Int64(available) < before.size
        {
            throw AndroidOpenError.noSpace
        }
        let work = root.appendingPathComponent(".work-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent(entry.name)
        try download(entry, payload, cancellation, progress)
        try check(cancellation)
        guard validCached(payload, size: before.size) else { throw AndroidOpenError.incomplete }
        guard try revision(entry) == before else { throw AndroidOpenError.changed }
        try check(cancellation)
        // Read-only prevents treating a disposable copy as a document synchronized back to Android.
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: payload.path)
        lock.lock()
        defer { lock.unlock() }
        try check(cancellation)
        if validCached(cached, size: before.size) {
            protected.insert(key)
            return cached
        }
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: work, to: directory)
        protected.insert(key)
        prune()
        return cached
    }

    private func validCached(_ url: URL, size: Int64) -> Bool {
        guard let folder = try? url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]),
            folder.isSymbolicLink != true,
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true
        else { return false }
        return Int64(values.fileSize ?? -1) == size
    }

    /// Caller holds the lock. Files opened in this app session stay available to external players.
    private func prune() {
        let fm = FileManager.default
        let folders =
            (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? []
        var candidates: [(URL, Date, Int64)] = []
        var total: Int64 = 0
        for folder in folders {
            let name = folder.lastPathComponent
            let published =
                name.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            guard published || name.hasPrefix(".work-"),
                let values = try? folder.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ]),
                values.isDirectory == true, values.isSymbolicLink != true
            else { continue }
            let date = values.contentModificationDate ?? .distantPast
            let bytes =
                ((try? fm.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []).reduce(Int64(0))
            { sum, url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                return sum + (values?.isSymbolicLink == true ? 0 : Int64(values?.fileSize ?? 0))
            }
            total += bytes
            if !protected.contains(name), published || Date().timeIntervalSince(date) > 7 * 86400 {
                candidates.append((folder, date, bytes))
            }
        }
        for (folder, date, bytes) in candidates.sorted(by: { $0.1 < $1.1 }) {
            if total > budget || Date().timeIntervalSince(date) > 7 * 86400 {
                if (try? fm.removeItem(at: folder)) != nil { total -= bytes }
            }
        }
    }
}
