import Foundation
import CryptoKit
import Darwin

struct DuplicateFileGroup: Identifiable {
    let id: String
    let files: [URL]
    let size: Int64
    var redundantBytes: Int64 { size * Int64(max(0, files.count - 1)) }
}
struct DuplicateScanProgress {
    var visited = 0
    var hashed = 0
    var candidates = 0
    var currentName = ""
}
struct DuplicateScanResult {
    var groups: [DuplicateFileGroup] = []
    var unreadable = 0
    var changed = 0
    var limited = false
    var cancelled = false
}

enum DuplicateFileService {
    private struct Candidate { let url: URL; let size: Int64; let inode: UInt64; let device: UInt64 }
    static func scan(_ root: URL, showHidden: Bool = false, limit: Int = 200_000,
                     token: ScanCancellation, progress: (DuplicateScanProgress) -> Void = { _ in }) -> DuplicateScanResult {
        let fm = FileManager.default
        var result = DuplicateScanResult()
        var status = DuplicateScanProgress()
        var sizes: [Int64: [Candidate]] = [:]
        var identities = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                            options: showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants],
                                            errorHandler: { _, _ in result.unreadable += 1; return true }) else {
            result.unreadable += 1; return result
        }
        for case let url as URL in enumerator {
            if token.isCancelled { result.cancelled = true; break }
            if status.visited >= limit { result.limited = true; break }
            status.visited += 1
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                // The enumerator does not follow symlinks. Pruning a file
                // here can skip the next real sibling directory on macOS.
                guard values.isSymbolicLink != true else { continue }
                guard values.isRegularFile == true else { continue }
                let attributes = try fm.attributesOfItem(atPath: url.path)
                guard let inode = attributes[.systemFileNumber] as? NSNumber,
                      let device = attributes[.systemNumber] as? NSNumber else { result.unreadable += 1; continue }
                // Multiple hard links are a single physical file, not removable duplicate copies.
                guard identities.insert("\(device):\(inode)").inserted else { continue }
                let size = Int64(values.fileSize ?? 0)
                sizes[size, default: []].append(Candidate(url: url, size: size, inode: inode.uint64Value, device: device.uint64Value))
            } catch { result.unreadable += 1 }
            if status.visited % 200 == 0 { progress(status) }
        }
        let candidates = sizes.values.filter { $0.count > 1 }.flatMap { $0 }
        status.candidates = candidates.count; progress(status)
        var hashes: [String: [Candidate]] = [:]
        for file in candidates {
            if token.isCancelled { result.cancelled = true; break }
            status.currentName = file.url.lastPathComponent
            progress(status)
            do {
                guard let hash = try digest(file, token: token) else {
                    if token.isCancelled { result.cancelled = true; break }
                    result.changed += 1; continue
                }
                hashes["\(file.size):\(hash)", default: []].append(file)
                status.hashed += 1
            } catch { result.unreadable += 1 }
        }
        result.groups = hashes.compactMap { key, files in
            files.count > 1 ? DuplicateFileGroup(id: key, files: files.map(\.url).sorted { $0.path < $1.path }, size: files[0].size) : nil
        }.sorted { $0.redundantBytes == $1.redundantBytes ? $0.id < $1.id : $0.redundantBytes > $1.redundantBytes }
        progress(status)
        return result
    }

    private static func digest(_ file: Candidate, token: ScanCancellation) throws -> String? {
        let descriptor = file.url.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              UInt64(before.st_ino) == file.inode, UInt64(truncatingIfNeeded: before.st_dev) == file.device, before.st_size == file.size else { return nil }
        var hash = SHA256()
        while true {
            if token.isCancelled { return nil }
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
