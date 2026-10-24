import Foundation

struct ArchiveMember: Identifiable, Equatable {
    let id: Int
    let path: String
    let size: Int64?
    let packedSize: Int64?
    let isDirectory: Bool
    let isLink: Bool
    let encrypted: Bool
    let method: String

    var canPreview: Bool { !isDirectory && !isLink && (size ?? 0) <= ArchiveService.memberPreviewLimit }
    var canOpenExternally: Bool {
        !isDirectory && !isLink && size.map { $0 >= 0 && $0 < ArchiveService.memberPreviewLimit } == true
    }
}

/// Browsing rows keep archive member IDs intact; inferred directories never become extraction targets.
struct ArchiveBrowserEntry: Identifiable {
    let id: String
    let path: String
    let member: ArchiveMember?
    let directory: Bool
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// Built once per listing, so selecting a row does not repeatedly walk the archive.
struct ArchiveDirectoryIndex {
    private var children: [String: [ArchiveBrowserEntry]] = [:]
    private var searchable: [ArchiveBrowserEntry] = []

    init(entries: [ArchiveMember] = []) {
        var folders: [String: ArchiveBrowserEntry] = [:]
        for member in entries {
            let parts = member.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            let path = parts.joined(separator: "/")
            let isFolder = member.isDirectory && !member.isLink
            if isFolder {
                folders[path] = ArchiveBrowserEntry(id: "folder:" + path, path: path, member: member, directory: true)
            } else {
                let row = ArchiveBrowserEntry(id: "member:\(member.id)", path: path, member: member, directory: false)
                children[parts.dropLast().joined(separator: "/"), default: []].append(row)
                searchable.append(row)
            }
            if parts.count > 1 {
                var parent = ""
                for part in parts.dropLast() {
                    parent = parent.isEmpty ? part : parent + "/" + part
                    if folders[parent] == nil {
                        folders[parent] = ArchiveBrowserEntry(id: "folder:" + parent, path: parent, member: nil, directory: true)
                    }
                }
            }
        }
        for folder in folders.values {
            let parent = folder.path.split(separator: "/").dropLast().joined(separator: "/")
            children[parent, default: []].append(folder)
            searchable.append(folder)
        }
        for key in Array(children.keys) { children[key]?.sort(by: Self.ordered) }
        searchable.sort(by: Self.ordered)
    }

    func rows(in directory: String = "", matching query: String = "") -> [ArchiveBrowserEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? children[directory] ?? [] : searchable.filter { $0.path.localizedStandardContains(query) }
    }

    private static func ordered(_ lhs: ArchiveBrowserEntry, _ rhs: ArchiveBrowserEntry) -> Bool {
        if lhs.directory != rhs.directory { return lhs.directory }
        let order = lhs.path.localizedStandardCompare(rhs.path)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}

struct ArchiveSourceStamp: Equatable {
    let inode: UInt64
    let device: UInt64
    let bytes: UInt64
    let modified: Date

    init(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let inode = values[.systemFileNumber] as? NSNumber,
              let device = values[.systemNumber] as? NSNumber,
              let bytes = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date else { throw ArchiveError.unsupported }
        self.inode = inode.uint64Value
        self.device = device.uint64Value
        self.bytes = bytes.uint64Value
        self.modified = modified
    }
}

/// Owns a private temporary workspace. The caller must close it after cancelling and awaiting work.
struct ArchiveContents {
    let archive: URL
    let sourceStamp: ArchiveSourceStamp
    let container: URL
    let workspace: URL
    let entries: [ArchiveMember]
    let expandedStream: Bool

    var totalSize: Int64 {
        entries.filter { !$0.isDirectory }.reduce(0) { sum, item in
            let value = item.size ?? 0
            return sum > Int64.max - value ? Int64.max : sum + value
        }
    }

    func close() { ArchiveService.removeStaging(workspace) }
}

struct ArchiveMemberPreview {
    let url: URL
    let directory: URL
    func close() { ArchiveService.removeStaging(directory) }
}

extension ArchiveService {
    static let memberPreviewLimit: Int64 = 64 * 1024 * 1024
    static let streamPreviewLimit: Int64 = 512 * 1024 * 1024

    static func parseContents(_ listing: String) throws -> [ArchiveMember] {
        try validateListing(listing)
        var entries: [ArchiveMember] = []
        var fields: [String: String] = [:]
        func append() throws {
            guard !fields.isEmpty else { return }
            guard let path = fields["Path"], !path.isEmpty else { throw ArchiveError.invalidListing }
            func size(_ key: String) throws -> Int64? {
                guard let raw = fields[key], !raw.isEmpty else { return nil }
                guard let value = Int64(raw), value >= 0 else { throw ArchiveError.invalidListing }
                return value
            }
            let attributes = fields["Attributes"] ?? fields["Mode"] ?? ""
            let directory = fields["Folder"] == "+" || attributes.hasPrefix("D") || attributes.hasPrefix("d")
            let link = !(fields["Symbolic Link"] ?? "").isEmpty || !(fields["Hard Link"] ?? "").isEmpty
                || attributes.split(separator: " ").contains(where: { $0.hasPrefix("l") })
            entries.append(ArchiveMember(id: entries.count, path: path, size: try size("Size"),
                packedSize: try size("Packed Size"), isDirectory: directory, isLink: link,
                encrypted: fields["Encrypted"] == "+", method: fields["Method"] ?? ""))
            guard entries.count <= 100_000 else { throw ArchiveError.invalidListing }
            fields.removeAll(keepingCapacity: true)
        }
        for line in listing.components(separatedBy: .newlines) {
            if line.isEmpty { try append(); continue }
            if fields.isEmpty && line == "Enter password:" { continue }
            guard let separator = line.range(of: " = ") else { throw ArchiveError.invalidListing }
            let key = String(line[..<separator.lowerBound])
            guard fields[key] == nil else { throw ArchiveError.invalidListing }
            fields[key] = String(line[separator.upperBound...])
        }
        try append()
        return entries
    }

    static func listMembers(_ archive: URL, engine: URL, password: String?, work: URL,
                            cancellation: ScanCancellation) throws -> [ArchiveMember] {
        var listing = try execute(engine: engine,
            arguments: ["l", "-slt", "-ba", "-sccUTF-8", "-bsp0", "--", archive.path],
            password: password, work: work, cancellation: cancellation)
        // Raw streams (XZ, LZMA, Zstandard) often have no stored filename or known size.
        if streamExtensions.contains(archive.pathExtension.lowercased()), !listing.contains("Path = ") {
            listing = "Path = \(archive.deletingPathExtension().lastPathComponent)\n" + listing
        }
        return try parseContents(listing)
    }

    /// Listing does not unpack normal containers. Compressed TAR streams require one bounded intermediate file.
    static func previewContents(_ selected: URL, password: String? = nil,
                                cancellation: ScanCancellation = ScanCancellation()) throws -> ArchiveContents {
        try checkCancellation(cancellation)
        guard selected.isFileURL, isArchive(selected) else { throw ArchiveError.unsupported }
        guard let engine = sevenZipURL else { throw ArchiveError.engineMissing }
        let archive = try firstVolume(for: selected)
        let stamp = try ArchiveSourceStamp(archive)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("WinFile-archive-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var container = archive
            var entries = try listMembers(archive, engine: engine, password: password, work: work, cancellation: cancellation)
            var expanded = false
            if streamExtensions.contains(archive.pathExtension.lowercased()), entries.count == 1,
               let stream = entries.first,
               tarSuffixes.contains(where: archive.lastPathComponent.lowercased().hasSuffix) || stream.path.lowercased().hasSuffix(".tar") {
                guard !stream.isDirectory, !stream.isLink,
                      stream.size.map({ $0 <= streamPreviewLimit }) ?? true else { throw ArchiveError.previewTooLarge }
                let payload = work.appendingPathComponent("stream")
                try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
                _ = try execute(engine: engine,
                    arguments: ["x", "-y", "-aos", "-spd", "-sccUTF-8", "-bso0", "-bsp0", "-o\(payload.path)", "--", archive.path],
                    password: password, work: work, cancellation: cancellation,
                    monitoredFile: payload, maximumFileBytes: streamPreviewLimit)
                try validateExtractedTree(payload, cancellation: cancellation)
                let children = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                guard children.count == 1, let target = children.first else { throw ArchiveError.invalidListing }
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      Int64(values.fileSize ?? 0) <= streamPreviewLimit,
                      isTarPayload(target, original: archive) else { throw ArchiveError.invalidListing }
                container = target
                entries = try listMembers(container, engine: engine, password: password, work: work, cancellation: cancellation)
                expanded = true
            }
            guard try ArchiveSourceStamp(archive) == stamp else { throw ArchiveError.archiveChanged }
            try checkCancellation(cancellation)
            return ArchiveContents(archive: archive, sourceStamp: stamp, container: container, workspace: work,
                                   entries: entries, expandedStream: expanded)
        } catch { removeStaging(work); throw error }
    }

    static func validateMember(_ member: ArchiveMember, contents: ArchiveContents, password: String?,
                               cancellation: ScanCancellation) throws {
        try checkCancellation(cancellation)
        guard contents.entries.contains(member), contents.entries.filter({ $0.path == member.path }).count == 1 else {
            throw ArchiveError.invalidListing
        }
        guard try ArchiveSourceStamp(contents.archive) == contents.sourceStamp else { throw ArchiveError.archiveChanged }
        guard let engine = sevenZipURL else { throw ArchiveError.engineMissing }
        let current = try listMembers(contents.container, engine: engine, password: password, work: contents.workspace, cancellation: cancellation)
        guard current == contents.entries else { throw ArchiveError.archiveChanged }
    }

    /// Extract one literal regular member to an isolated read-only copy; never launch its default app.
    static func prepareMemberPreview(_ member: ArchiveMember, contents: ArchiveContents, password: String? = nil,
                                     cancellation: ScanCancellation = ScanCancellation()) throws -> ArchiveMemberPreview {
        guard member.canPreview else { throw ArchiveError.previewTooLarge }
        try validateMember(member, contents: contents, password: password, cancellation: cancellation)
        guard let engine = sevenZipURL else { throw ArchiveError.engineMissing }
        let payload = contents.workspace.appendingPathComponent("member-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        do {
            _ = try execute(engine: engine,
                arguments: ["x", "-y", "-aos", "-spd", "-sccUTF-8", "-bso0", "-bsp0", "-o\(payload.path)", "--", contents.container.path, member.path],
                password: password, work: contents.workspace, cancellation: cancellation,
                monitoredFile: payload, maximumFileBytes: memberPreviewLimit)
            try validateExtractedTree(payload, cancellation: cancellation)
            let target: URL
            if streamExtensions.contains(contents.container.pathExtension.lowercased()) {
                let children = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                guard children.count == 1, let only = children.first else { throw ArchiveError.invalidListing }
                target = only
            } else { target = payload.appendingPathComponent(member.path) }
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, member.size == nil || Int64(size) == member.size,
                  Int64(size) <= memberPreviewLimit else {
                throw ArchiveError.invalidListing
            }
            guard try ArchiveSourceStamp(contents.archive) == contents.sourceStamp else { throw ArchiveError.archiveChanged }
            try checkCancellation(cancellation)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            return ArchiveMemberPreview(url: target, directory: payload)
        } catch { removeStaging(payload); throw error }
    }
}
