import Darwin
import Foundation

extension ArchiveService {
    static var sevenZipURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("vendor/7zip/7zz")
        let candidates = Bundle.main.bundleURL.pathExtension == "app" ? [bundled] : [development]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Normalize a selected volume to the first part; selecting several parts runs once.
    static func firstVolume(for archive: URL) throws -> URL {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        var firstName: String?
        if let range = name.range(of: #"\.part([0-9]+)\.rar$"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = String(name[range]).dropFirst(5).dropLast(4)
            firstName = String(name[..<range.lowerBound]) + ".part" + String(repeating: "0", count: max(0, digits.count - 1)) + "1.rar"
        } else if lower.range(of: #"\.(7z|zip|zipx)\.[0-9]{3,}$"#, options: .regularExpression) != nil {
            firstName = archive.deletingPathExtension().lastPathComponent + "." + String(repeating: "0", count: max(2, archive.pathExtension.count - 1)) + "1"
        } else if lower.range(of: #"\.r[0-9]{2,3}$"#, options: .regularExpression) != nil {
            firstName = archive.deletingPathExtension().lastPathComponent + ".rar"
        } else if lower.range(of: #"\.z[0-9]{2,3}$"#, options: .regularExpression) != nil {
            let stem = archive.deletingPathExtension()
            let zip = stem.appendingPathExtension("zip")
            let zipx = stem.appendingPathExtension("zipx")
            firstName = FileManager.default.fileExists(atPath: zipx.path) && !FileManager.default.fileExists(atPath: zip.path) ? zipx.lastPathComponent : zip.lastPathComponent
        }
        guard let firstName else { return archive }
        let parent = archive.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        guard let actual = names.sorted().first(where: { $0.caseInsensitiveCompare(firstName) == .orderedSame }) else {
            throw ArchiveError.missingVolume(firstName)
        }
        return parent.appendingPathComponent(actual)
    }

    static func extractionBaseName(_ archive: URL) -> String {
        var name = archive.lastPathComponent
        for suffix in tarSuffixes + [".7z.001", ".zip.001", ".zipx.001"] {
            if name.lowercased().hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        if let range = name.range(of: #"\.part[0-9]+\.rar$"#, options: [.regularExpression, .caseInsensitive]) {
            name = String(name[..<range.lowerBound])
        } else { name = (name as NSString).deletingPathExtension }
        return name.isEmpty ? "Archive" : name
    }

    /// Extract privately on the destination volume, then publish complete results without overwriting.
    @discardableResult
    static func extract(_ selected: URL, to destination: URL, password: String? = nil,
                        createFolder: Bool = false, cancellation: ScanCancellation = ScanCancellation(),
                        onProgress: @escaping (Double?) -> Void = { _ in }) throws -> [URL] {
        try checkCancellation(cancellation)
        guard selected.isFileURL, isArchive(selected) else { throw ArchiveError.unsupported }
        guard let engine = sevenZipURL else { throw ArchiveError.engineMissing }
        let archive = try firstVolume(for: selected)
        let fm = FileManager.default
        let work = destination.resolvingSymlinksInPath().appendingPathComponent(".WinFile-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { removeStaging(work) }
        var payload = work.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        try unpack(archive, into: payload, work: work, engine: engine, password: password,
                   cancellation: cancellation, onProgress: onProgress)
        // gzip/bzip2/xz are streams. Only unwrap a TAR payload; report.txt.gz stays report.txt.
        if streamExtensions.contains(archive.pathExtension.lowercased()) {
            let children = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isRegularFileKey])
            if children.count == 1, let inner = children.first,
               (try? inner.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
               isTarPayload(inner, original: archive) {
                let nested = work.appendingPathComponent("tar-payload")
                try fm.createDirectory(at: nested, withIntermediateDirectories: false)
                try unpack(inner, into: nested, work: work, engine: engine, password: password,
                           cancellation: cancellation, onProgress: onProgress)
                payload = nested
            }
        }
        try validateExtractedTree(payload, cancellation: cancellation)
        try checkCancellation(cancellation)
        let metadata = payload.appendingPathComponent("__MACOSX")
        if existsWithoutFollowing(metadata) { try fm.removeItem(at: metadata) }
        let names = try fm.contentsOfDirectory(atPath: payload.path).filter { $0 != "__MACOSX" }.sorted()
        if names.isEmpty { onProgress(1); return [] }
        let collision = names.contains { existsWithoutFollowing(destination.appendingPathComponent($0)) }
        if createFolder || collision {
            let base = extractionBaseName(archive)
            var target = uniqueExtractFolder(in: destination, baseName: base)
            if createFolder {
                target = destination.appendingPathComponent(base)
                var number = 2
                while existsWithoutFollowing(target) {
                    target = destination.appendingPathComponent("\(base) \(number)"); number += 1
                }
            }
            // No merging: rename the whole finished directory in one operation.
            try fm.moveItem(at: payload, to: target)
            onProgress(1)
            return [target]
        }
        var committed: [(source: URL, target: URL, identity: FileMoveRecord?)] = []
        do {
            for name in names {
                let source = payload.appendingPathComponent(name)
                let target = destination.appendingPathComponent(name)
                try fm.moveItem(at: source, to: target)
                committed.append((source, target, FileMoveRecord(original: source, current: target)))
            }
        } catch {
            // Undo our already-published items if a destination changes during commit.
            for pair in committed.reversed() where pair.identity?.stillExists == true {
                try? fm.moveItem(at: pair.target, to: pair.source)
            }
            throw error
        }
        onProgress(1)
        return committed.map(\.target)
    }

    static func isTarPayload(_ url: URL, original: URL) -> Bool {
        let lower = original.lastPathComponent.lowercased()
        if tarSuffixes.contains(where: lower.hasSuffix) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 512)
        return data.count >= 262 && String(data: data[257..<262], encoding: .ascii) == "ustar"
    }

    private static func unpack(_ archive: URL, into payload: URL, work: URL, engine: URL,
                               password: String?, cancellation: ScanCancellation,
                               onProgress: @escaping (Double?) -> Void) throws {
        onProgress(nil)
        let listing = try execute(engine: engine, arguments: ["l", "-slt", "-ba", "-sccUTF-8", "-bsp0", "--", archive.path],
                                  password: password, work: work, cancellation: cancellation)
        try validateListing(listing)
        if listing.contains("Encrypted = +"), password == nil { throw ArchiveError.passwordRequired }
        let required = listing.components(separatedBy: "\n").filter { $0.hasPrefix("Size = ") }
            .compactMap { Int64($0.dropFirst(7).trimmingCharacters(in: .whitespaces)) }
            .reduce(Int64(0)) { sum, value in sum > Int64.max - max(0, value) ? Int64.max : sum + max(0, value) }
        if let free = (try? FileManager.default.attributesOfFileSystem(forPath: work.path)[.systemFreeSize]) as? NSNumber,
           required > free.int64Value { throw ArchiveError.insufficientSpace }
        let hasZipVolumes = ["z01", "Z01"].contains {
            existsWithoutFollowing(archive.deletingPathExtension().appendingPathExtension($0))
        }
        let zipMethods = listing.components(separatedBy: "\n").filter { $0.hasPrefix("Method = ") }
            .map { String($0.dropFirst(9)) }
        let metadataCompatibleZip = zipMethods.allSatisfy { $0 == "Store" || $0 == "Deflate" }
        if archive.pathExtension.lowercased() == "zip", !hasZipVolumes, !listing.contains("Encrypted = +"), metadataCompatibleZip {
            // Preserve macOS resource forks and metadata for ordinary ZIP archives.
            _ = try execute(engine: URL(fileURLWithPath: "/usr/bin/ditto"),
                            arguments: ["-x", "-k", archive.path, payload.path], password: nil,
                            work: work, cancellation: cancellation)
        } else {
            _ = try execute(engine: engine, arguments: ["x", "-y", "-aos", "-sccUTF-8", "-bso0", "-bsp1", "-bse1", "-o\(payload.path)", "--", archive.path],
                            password: password, work: work, cancellation: cancellation, onProgress: onProgress)
        }
    }

    static func validateListing(_ listing: String) throws {
        for line in listing.components(separatedBy: "\n") {
            if line.hasPrefix("Hard Link = ") {
                let target = String(line.dropFirst(12)).replacingOccurrences(of: "\\", with: "/")
                if target.hasPrefix("/") || target.split(separator: "/").contains("..") { throw ArchiveError.unsafePath }
            }
            if line.hasPrefix("Path = ") {
                let path = String(line.dropFirst(7)).trimmingCharacters(in: .newlines)
                let normalized = path.replacingOccurrences(of: "\\", with: "/")
                guard !normalized.hasPrefix("/"), !normalized.contains("\0"),
                      normalized.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
                      !normalized.split(separator: "/").contains("..") else { throw ArchiveError.unsafePath }
            }
        }
    }

    static func validateExtractedTree(_ root: URL, cancellation: ScanCancellation) throws {
        let fm = FileManager.default
        let canonical = root.resolvingSymlinksInPath().path + "/"
        var readError: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, error in
            readError = error; return false
        }) else { throw ArchiveError.unsafePath }
        for case let url as URL in iterator {
            try checkCancellation(cancellation)
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let target = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard target.hasPrefix(canonical) || target == String(canonical.dropLast()) else { throw ArchiveError.unsafePath }
                iterator.skipDescendants()
            }
        }
        if let readError { throw readError }
    }

    private static func existsWithoutFollowing(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    static func removeStaging(_ root: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let entry as URL in entries {
                guard let info = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), info.isSymbolicLink != true else { continue }
                if info.isDirectory == true { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.path) }
            }
        }
        try? fm.removeItem(at: root)
    }
    static func checkCancellation(_ token: ScanCancellation) throws {
        if token.isCancelled { throw ArchiveError.cancelled }
    }

    /// Log to a private file so stdout/stderr cannot deadlock each other's pipes.
    /// Passwords go through stdin, never process arguments or saved preferences.
    static func execute(engine: URL, arguments: [String], password: String?, work: URL,
                        cancellation: ScanCancellation, onProgress: ((Double?) -> Void)? = nil,
                        monitoredFile: URL? = nil, maximumFileBytes: Int64 = Int64.max) throws -> String {
        try checkCancellation(cancellation)
        let logURL = work.appendingPathComponent("engine-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        // Restrict only this child process's writes; archive members cannot escape the private staging area.
        guard let canonicalPath = realpath(work.path, nil) else { throw ArchiveError.unsafePath }
        let realWork = String(cString: canonicalPath)
        free(canonicalPath)
        let escaped = realWork.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"\(escaped)\") (literal \"/dev/null\"))", engine.path] + arguments
        process.currentDirectoryURL = work
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = log
        process.standardError = log
        guard (password?.utf8.count ?? 0) <= 4096 else { throw ArchiveError.wrongPassword }
        input.fileHandleForWriting.write(Data(((password ?? "") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        try process.run()
        var stoppingAt: Date?
        var lastProgress: Double?
        var limitError: ArchiveError?
        while process.isRunning {
            if (((try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber)?.int64Value ?? 0) > 32 * 1024 * 1024 {
                limitError = .invalidListing
            }
            if let monitoredFile, monitoredBytes(at: monitoredFile) > maximumFileBytes {
                limitError = .previewTooLarge
            }
            if cancellation.isCancelled || limitError != nil {
                if stoppingAt == nil { process.terminate(); stoppingAt = Date() }
                else if Date().timeIntervalSince(stoppingAt!) > 2 { kill(process.processIdentifier, SIGKILL) }
            }
            if let onProgress, let data = try? tail(logURL, count: 2048),
               let output = String(data: data, encoding: .utf8) {
                let regex = try! NSRegularExpression(pattern: #"([0-9]{1,3})%"#)
                let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
                if let last = matches.last, let range = Range(last.range(at: 1), in: output),
                   let percent = Double(output[range]), lastProgress != percent {
                    lastProgress = percent; onProgress(min(0.99, percent / 100))
                }
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        process.waitUntilExit()
        try checkCancellation(cancellation)
        if let limitError { throw limitError }
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 32 * 1024 * 1024 else {
            throw ArchiveError.commandFailed(L("archive.error.listingTooLarge", "压缩包目录信息过大，无法完成验证。"), -1)
        }
        let output = String(data: try Data(contentsOf: logURL), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let lower = output.lowercased()
            if lower.contains("wrong password") || lower.contains("password is incorrect") || lower.contains("enter password") {
                throw password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
            }
            if lower.contains("missing volume") || lower.contains("cannot find volume") || lower.contains("unexpected end of archive") {
                throw ArchiveError.missingVolume("")
            }
            throw ArchiveError.commandFailed(String(output.suffix(3000)).trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
        }
        return output
    }

    private static func tail(_ url: URL, count: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > count ? size - count : 0)
        return handle.readData(ofLength: Int(count))
    }

    private static func monitoredBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let values = try? fm.attributesOfItem(atPath: url.path) else { return 0 }
        if values[.type] as? FileAttributeType != .typeDirectory {
            return (values[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let entries = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in entries {
            guard let info = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), info.isRegularFile == true else { continue }
            let size = Int64(info.fileSize ?? 0)
            total = total > Int64.max - size ? Int64.max : total + size
        }
        return total
    }
}
