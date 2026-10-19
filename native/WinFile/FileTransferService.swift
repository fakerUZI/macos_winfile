import Foundation
import Darwin

struct FileTransferProgress {
    var total: Int
    var completed = 0
    var currentName = ""
    var isMoving: Bool
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
}
struct FileTransferOutcome {
    var completed: [URL] = []
    var moves: [FileMoveRecord] = []
    var failures: [String] = []
    var cancelled = false
    var retryURLs: [URL] = []
    var destination: URL?
    var isMoving = false
    var clipboardGeneration: Int?
}

/// Copies metadata and data through macOS copyfile into private destination staging.
/// The callback reports actual copied bytes and can interrupt the current data stream.
enum FileTransferService {
    private final class CopyContext {
        let token: ScanCancellation
        let update: (Int64, String) -> Void
        var copied: Int64 = 0
        var lastFileBytes: Int64 = 0
        init(token: ScanCancellation, update: @escaping (Int64, String) -> Void) { self.token = token; self.update = update }
    }
    private static let callback: copyfile_callback_t = { what, stage, state, source, _, raw in
        guard let raw else { return Int32(COPYFILE_QUIT) }
        let context = Unmanaged<CopyContext>.fromOpaque(raw).takeUnretainedValue()
        if context.token.isCancelled { return Int32(COPYFILE_QUIT) }
        if stage == COPYFILE_ERR || what == COPYFILE_RECURSE_ERROR { return Int32(COPYFILE_QUIT) }
        if what == COPYFILE_COPY_DATA {
            if stage == COPYFILE_START { context.lastFileBytes = 0 }
            var bytes: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes) == 0 {
                context.copied += max(0, Int64(bytes) - context.lastFileBytes)
                context.lastFileBytes = Int64(bytes)
                context.update(context.copied, source.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "")
            }
        }
        return Int32(COPYFILE_CONTINUE)
    }
    private static func copy(_ source: URL, to target: URL, token: ScanCancellation,
                             update: @escaping (Int64, String) -> Void) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(token: token, update: update)
        let raw = Unmanaged.passUnretained(context).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), raw)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        let result = source.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in Darwin.copyfile(from, to, state, flags) }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        withExtendedLifetime(context) {}
    }

    static func transfer(_ items: [FileItem], to directory: URL, mode: FSEngine.TransferMode,
                         token: ScanCancellation, onProgress: @escaping (FileTransferProgress) -> Void) -> FileTransferOutcome {
        var outcome = FileTransferOutcome(destination: directory, isMoving: mode == .move)
        var progress = FileTransferProgress(total: items.count, isMoving: mode == .move)
        onProgress(progress)
        var sizes: [String: Int64] = [:]
        var complete = true
        for item in items {
            if token.isCancelled { break }
            if item.isDirectory && !item.isSymlink {
                let size = FileSystemService.directorySize(item.url, cancelled: { token.isCancelled })
                sizes[item.id] = size.bytes; complete = complete && size.isComplete
            } else { sizes[item.id] = item.isSymlink ? 0 : (item.size ?? 0) }
        }
        progress.totalBytes = complete ? sizes.values.reduce(0, +) : nil
        let fm = FileManager()
        var finished = Set<String>()
        for item in items {
            if token.isCancelled { outcome.cancelled = true; break }
            progress.currentName = item.name
            onProgress(progress)
            do {
                let destinationPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
                let sourcePath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
                if item.isDirectory && !item.isSymlink && (destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/")) { throw FSError.recursiveTransfer(item.name) }
                var target = FSEngine.uniqueURL(in: directory, name: item.name, isDirectory: item.isDirectory)
                if mode == .move, item.url.deletingLastPathComponent().path == directory.path {
                    target = item.url
                } else if mode == .copy {
                    let staging = directory.appendingPathComponent(".WinFile-transfer-\(UUID().uuidString)")
                    try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
                    defer { try? fm.removeItem(at: staging) }
                    let temporary = staging.appendingPathComponent(item.name)
                    let baseline = progress
                    var lastUpdate = Date.distantPast
                    var reportedBytes = false
                    try copy(item.url, to: temporary, token: token) { bytes, name in
                        if (bytes > 0 && !reportedBytes) || Date().timeIntervalSince(lastUpdate) >= 0.08 || token.isCancelled {
                            var update = baseline
                            update.completedBytes += bytes; update.currentName = name
                            onProgress(update); lastUpdate = Date(); reportedBytes = reportedBytes || bytes > 0
                        }
                    }
                    if token.isCancelled { outcome.cancelled = true; break }
                    target = FSEngine.uniqueURL(in: directory, name: item.name, isDirectory: item.isDirectory)
                    try fm.moveItem(at: temporary, to: target)
                } else {
                    try fm.moveItem(at: item.url, to: target)
                    if let record = FileMoveRecord(original: item.url, current: target) { outcome.moves.append(record) }
                }
                outcome.completed.append(target); finished.insert(item.id)
                progress.completed += 1; progress.completedBytes += sizes[item.id] ?? 0
                onProgress(progress)
            } catch {
                if token.isCancelled { outcome.cancelled = true; break }
                outcome.failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        outcome.cancelled = outcome.cancelled || token.isCancelled
        outcome.retryURLs = items.filter { !finished.contains($0.id) }.map(\.url)
        return outcome
    }
}
