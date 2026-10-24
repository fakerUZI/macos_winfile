import Combine
import Foundation

struct ArchivePreviewRequest: Identifiable {
    let id = UUID()
    let archive: URL
    let destination: URL
}

@MainActor
final class ArchivePreviewModel: ObservableObject {
    @Published private(set) var directoryIndex = ArchiveDirectoryIndex()
    @Published private(set) var contents: ArchiveContents?
    @Published private(set) var isLoading = false
    @Published private(set) var isPreparing = false
    @Published private(set) var needsPassword = false
    @Published private(set) var error: String?
    @Published private(set) var preview: ArchiveMemberPreview?
    private var password: String?
    private var loadToken: ScanCancellation?
    private var memberToken: ScanCancellation?
    private var loadTask: Task<Void, Never>?
    private var memberTask: Task<Void, Never>?
    private(set) var cleanupTask: Task<Void, Never>?
    private var loadID = UUID()
    private var memberID = UUID()
    private var closed = false
    let archive: URL

    init(archive: URL) { self.archive = archive }

    func load(password: String? = nil) {
        guard !closed, !isLoading, contents == nil else { return }
        self.password = password
        let token = ScanCancellation()
        let id = UUID()
        let url = archive
        loadID = id; loadToken = token
        isLoading = true; needsPassword = false; error = nil
        loadTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let contents = try ArchiveService.previewContents(url, password: password, cancellation: token)
                    return (contents, ArchiveDirectoryIndex(entries: contents.entries))
                }.value
                guard let self, !self.closed, self.loadID == id else { result.0.close(); return }
                self.directoryIndex = result.1
                self.contents = result.0
            } catch {
                guard let self, !self.closed, self.loadID == id else { return }
                if case ArchiveError.passwordRequired = error { self.needsPassword = true }
                else if case ArchiveError.wrongPassword = error { self.needsPassword = true; self.error = error.localizedDescription }
                else if !token.isCancelled { self.error = error.localizedDescription }
            }
            guard let self, self.loadID == id else { return }
            self.isLoading = false
            self.loadTask = nil
        }
    }

    func show(_ member: ArchiveMember, password: String? = nil) {
        guard !closed, let contents, !isPreparing, member.canPreview else { return }
        clearPreview()
        let token = ScanCancellation()
        let id = UUID()
        let secret = password ?? self.password
        if let password { self.password = password }
        memberID = id; memberToken = token
        isPreparing = true; needsPassword = false; error = nil
        let previous = memberTask
        memberTask = Task { [weak self] in
            await previous?.value
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ArchiveService.prepareMemberPreview(member, contents: contents, password: secret, cancellation: token)
                }.value
                guard let self, !self.closed, self.memberID == id else { result.close(); return }
                self.preview = result
            } catch {
                guard let self, !self.closed, self.memberID == id else { return }
                if case ArchiveError.passwordRequired = error { self.needsPassword = true }
                else if case ArchiveError.wrongPassword = error { self.needsPassword = true; self.error = error.localizedDescription }
                else if !token.isCancelled { self.error = error.localizedDescription }
            }
            guard let self, self.memberID == id else { return }
            self.isPreparing = false
            self.memberTask = nil
        }
    }

    func clearPreview() {
        memberToken?.cancel()
        memberID = UUID()
        isPreparing = false
        needsPassword = false
        if contents != nil { error = nil }
        let old = preview
        preview = nil
        // Let the embedded Quick Look view release the file before removing its private copy.
        if let old { DispatchQueue.main.async { old.close() } }
    }

    func close() {
        guard !closed else { return }
        closed = true
        isLoading = false; isPreparing = false
        loadToken?.cancel(); memberToken?.cancel()
        password = nil
        preview = nil
        let contents = contents
        self.contents = nil
        let loading = loadTask, preparing = memberTask
        cleanupTask = Task {
            await loading?.value
            await preparing?.value
            contents?.close()
        }
    }
}
