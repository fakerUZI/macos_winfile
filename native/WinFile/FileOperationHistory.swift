import AppKit
import Combine

struct FileMoveRecord {
    let original: URL
    let current: URL
    let inode: UInt64
    let device: UInt64
    init?(original: URL, current: URL) {
        guard let values = try? FileManager.default.attributesOfItem(atPath: current.path),
              let inode = values[.systemFileNumber] as? NSNumber,
              let device = values[.systemNumber] as? NSNumber else { return nil }
        self.original = original
        self.current = current
        self.inode = inode.uint64Value
        self.device = device.uint64Value
    }
    var stillExists: Bool {
        guard let values = try? FileManager.default.attributesOfItem(atPath: current.path) else { return false }
        return (values[.systemFileNumber] as? NSNumber)?.uint64Value == inode
            && (values[.systemNumber] as? NSNumber)?.uint64Value == device
    }
}

@MainActor
final class FileOperationHistory: ObservableObject {
    static let shared = FileOperationHistory()
    struct Step {
        let title: String
        var moves: [FileMoveRecord]
        var batchRename = false
    }
    @Published private(set) var steps: [Step] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    var canUndo: Bool { !steps.isEmpty && !isBusy }
    var undoTitle: String { steps.last.map { L("operation.undoNamed", "撤销%@", $0.title) } ?? L("operation.undo", "撤销文件操作") }
    func record(title: String, moves: [FileMoveRecord], batchRename: Bool = false) {
        guard !moves.isEmpty else { return }
        steps.append(Step(title: title, moves: moves, batchRename: batchRename))
        if steps.count > 30 { steps.removeFirst(steps.count - 30) }
    }
    func undo() {
        guard canUndo, let step = steps.popLast() else { return }
        isBusy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                step.batchRename ? BatchRenameService.undo(step.moves) : Self.restore(step.moves)
            }.value
            if !outcome.remaining.isEmpty { steps.append(Step(title: step.title, moves: outcome.remaining, batchRename: step.batchRename)) }
            errorMessage = outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "\n")
            isBusy = false
            NotificationCenter.default.post(name: .winFileFilesChanged, object: nil)
        }
    }
    /// Partial failures remain available for retry; an existing destination is never overwritten.
    nonisolated static func restore(_ moves: [FileMoveRecord]) -> (remaining: [FileMoveRecord], errors: [String]) {
        var remaining: [FileMoveRecord] = []
        var errors: [String] = []
        for move in moves.reversed() {
            do {
                guard move.stillExists else { throw FSError.notFound(move.current) }
                guard !FileManager.default.fileExists(atPath: move.original.path) else { throw FSError.nameExists(move.original.lastPathComponent) }
                try FileManager.default.moveItem(at: move.current, to: move.original)
            } catch { remaining.insert(move, at: 0); errors.append("\(move.current.lastPathComponent): \(error.localizedDescription)") }
        }
        return (remaining, errors)
    }
}

extension Notification.Name {
    static let winFileFilesChanged = Notification.Name("WinFileFilesChanged")
}
