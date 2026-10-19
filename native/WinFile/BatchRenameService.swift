import Foundation

struct BatchRenameRules: Hashable {
    var find = ""
    var replacement = ""
    var prefix = ""
    var suffix = ""
    var numbered = false
    var baseName = ""
    var start = 1
    var digits = 3
}
struct BatchRenameEntry: Identifiable {
    var id: String { source.path }
    let source: URL
    let target: URL
    let identity: FileMoveRecord?
    var issue: String?
    var changes: Bool { source.path != target.path }
}
struct BatchRenamePlan {
    let rules: BatchRenameRules
    var entries: [BatchRenameEntry]
    var canApply: Bool { entries.contains(where: \.changes) && entries.allSatisfy { $0.issue == nil } }
}
struct BatchRenameOutcome {
    var moves: [FileMoveRecord] = []
    var errors: [String] = []
}

enum BatchRenameService {
    static func undo(_ moves: [FileMoveRecord]) -> (remaining: [FileMoveRecord], errors: [String]) {
        guard moves.allSatisfy(\.stillExists) else {
            return (moves, [L("rename.undoChanged", "文件已移动或被替换，无法撤销此批次")])
        }
        let entries = moves.map { move in
            BatchRenameEntry(source: move.current, target: move.original,
                             identity: FileMoveRecord(original: move.current, current: move.current))
        }
        let result = apply(BatchRenamePlan(rules: BatchRenameRules(), entries: entries))
        guard !result.errors.isEmpty else { return ([], []) }
        let remaining = moves.compactMap { move -> FileMoveRecord? in
            if let relocated = result.moves.first(where: { $0.original == move.current }) {
                return FileMoveRecord(original: move.original, current: relocated.current)
            }
            return move.stillExists ? move : nil
        }
        return (remaining, result.errors)
    }
    static func preview(_ items: [FileItem], rules: BatchRenameRules) -> BatchRenamePlan {
        let fm = FileManager.default
        var entries = items.enumerated().map { index, item -> BatchRenameEntry in
            let ext = item.isDirectory ? "" : item.url.pathExtension
            var stem = ext.isEmpty ? item.name : item.url.deletingPathExtension().lastPathComponent
            if !rules.find.isEmpty { stem = stem.replacingOccurrences(of: rules.find, with: rules.replacement) }
            if rules.numbered {
                let number = min(999_999_999, max(0, rules.start)) + index
                let formatted = String(format: "%0*d", min(9, max(1, rules.digits)), number)
                stem = (rules.baseName.isEmpty ? stem : rules.baseName) + "-" + formatted
            }
            let name = rules.prefix + stem + rules.suffix + (ext.isEmpty ? "" : "." + ext)
            let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
            let identity = FileMoveRecord(original: item.url, current: item.url)
            let invalid = name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains(":") || name.contains("\0") || name.utf8.count > 255
            return BatchRenameEntry(source: item.url, target: target, identity: identity,
                                    issue: invalid ? L("rename.invalid", "名称无效或过长") : identity == nil ? L("rename.missing", "源文件已不存在") : nil)
        }
        let sourcePaths = Set(entries.map { $0.source.standardizedFileURL.path })
        var targetKeys = Set<String>()
        for index in entries.indices {
            let entry = entries[index]
            if entries.contains(where: { other in other.id != entry.id && entry.source.path.hasPrefix(other.source.path + "/") }) {
                entries[index].issue = L("rename.nested", "请分别重命名文件夹及其内部文件")
            }
            let parent = entry.target.deletingLastPathComponent()
            let caseSensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
            let key = caseSensitive ? entry.target.path.precomposedStringWithCanonicalMapping : entry.target.path.precomposedStringWithCanonicalMapping.lowercased()
            if !targetKeys.insert(key).inserted { entries[index].issue = L("rename.duplicate", "批次内目标名称重复") }
            let exists = (try? fm.attributesOfItem(atPath: entry.target.path)) != nil
            if entry.changes, exists, !sourcePaths.contains(entry.target.standardizedFileURL.path) {
                // Permit case-only changes when both paths refer to the very same file.
                let targetIdentity = FileMoveRecord(original: entry.target, current: entry.target)
                if targetIdentity?.inode != entry.identity?.inode || targetIdentity?.device != entry.identity?.device {
                    entries[index].issue = L("rename.exists", "目标已存在")
                }
            }
        }
        return BatchRenamePlan(rules: rules, entries: entries)
    }

    static func apply(_ plan: BatchRenamePlan) -> BatchRenameOutcome {
        guard plan.canApply else { return BatchRenameOutcome(errors: [L("rename.review", "请先解决预览中的名称冲突")]) }
        let fm = FileManager.default
        let entries = plan.entries.filter(\.changes)
        var locations: [String: URL] = [:]
        do {
            // Validate all source identities before moving even the first item.
            for entry in entries {
                guard entry.identity?.stillExists == true else { throw FSError.notFound(entry.source) }
            }
            for entry in entries {
                let temporary = entry.source.deletingLastPathComponent().appendingPathComponent(".WinFile-rename-\(UUID().uuidString)")
                try fm.moveItem(at: entry.source, to: temporary)
                locations[entry.id] = temporary
            }
            for entry in entries {
                guard let temporary = locations[entry.id] else { continue }
                // moveItem refuses to replace any file created since preview.
                try fm.moveItem(at: temporary, to: entry.target)
                locations[entry.id] = entry.target
            }
            return BatchRenameOutcome(moves: entries.compactMap { FileMoveRecord(original: $0.source, current: $0.target) })
        } catch {
            let moves = entries.compactMap { entry in locations[entry.id].flatMap { FileMoveRecord(original: entry.source, current: $0) } }
            let rollback = FileOperationHistory.restore(moves)
            return BatchRenameOutcome(moves: rollback.remaining,
                                      errors: [error.localizedDescription] + rollback.errors)
        }
    }
}
