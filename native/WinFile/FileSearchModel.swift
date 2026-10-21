import Combine
import Foundation

struct FileSearchRequest: Equatable {
    var root: URL
    var query: String
    var criteria = FileSearchCriteria()
    var recursive = true
    var showHidden = false

    var isValid: Bool {
        root.isFileURL && criteria.isValid
            && (!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || criteria.isActive)
    }
}

/// The search sheet owns its scan: navigating or closing it never changes a browser tab's search state.
@MainActor
final class FileSearchModel: ObservableObject {
    @Published private(set) var report = FileScanReport()
    @Published private(set) var isSearching = false
    @Published private(set) var visited = 0
    @Published private(set) var request: FileSearchRequest?
    @Published private(set) var error: String?
    private var cancellation: ScanCancellation?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var resultLimit = 400
    private var entryLimit = 100_000

    var canExpand: Bool {
        !isSearching && ((report.limitReached && resultLimit < 5_000)
            || (report.visitLimitReached && entryLimit < 1_000_000) || report.cancelled)
    }

    func search(_ request: FileSearchRequest, expanding: Bool = false) {
        guard request.isValid else { return }
        cancellation?.cancel(); task?.cancel()
        let id = UUID(); generation = id
        self.request = request
        if !expanding { resultLimit = 400; entryLimit = 100_000 }
        error = nil; report = FileScanReport(); visited = 0; isSearching = true
        let token = ScanCancellation(); cancellation = token
        let limit = resultLimit, budget = entryLimit
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FileSystemService.searchReport(under: request.root,
                    matching: request.query.trimmingCharacters(in: .whitespacesAndNewlines),
                    limit: limit, entryLimit: budget, showHidden: request.showHidden,
                    criteria: request.criteria, recursive: request.recursive,
                    progress: { count in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == id else { return }
                            self.visited = max(self.visited, count)
                        }
                    }, cancelled: { token.isCancelled })
            }.value
            guard let self, self.generation == id, !Task.isCancelled else { return }
            self.report = result; self.visited = result.visited; self.isSearching = false
            if result.inaccessibleCount > 0 {
                self.error = L("search.unreadable", "%d 个位置无法读取，结果可能不完整。", result.inaccessibleCount)
            }
            self.task = nil; self.cancellation = nil
        }
    }

    func expand() {
        guard canExpand, let request else { return }
        if report.limitReached { resultLimit = min(5_000, resultLimit * 2) }
        if report.visitLimitReached { entryLimit = min(1_000_000, entryLimit * 2) }
        search(request, expanding: true)
    }

    /// A stopped scan returns the matches collected so far; dismissal discards all pending callbacks.
    func stop() { cancellation?.cancel() }
    func close() {
        generation = UUID(); cancellation?.cancel(); task?.cancel(); task = nil
        cancellation = nil; isSearching = false
    }
    deinit { cancellation?.cancel(); task?.cancel() }
}
