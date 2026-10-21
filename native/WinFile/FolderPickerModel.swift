import AppKit
import Combine
import Foundation

/// A separate browser for the picker; navigating here never changes an open tab.
@MainActor
final class FolderPickerModel: ObservableObject {
    @Published private(set) var directory: URL
    @Published private(set) var folders: [URL] = []
    @Published var selectedPaths: Set<String> = []
    @Published var pathText = ""
    @Published var search = ""
    @Published var showHidden = false { didSet { if oldValue != showHidden { navigate(to: directory) } } }
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?

    init(initialDirectory: URL?) {
        let home = FileSystemService.realHomeDirectory()
        directory = initialDirectory.flatMap { FSEngine.isSidebarFolder($0) ? $0 : nil } ?? home
        pathText = directory.path
    }

    var visibleFolders: [URL] {
        folders.filter { search.isEmpty || $0.lastPathComponent.localizedStandardContains(search) }
    }

    var candidates: [URL] {
        if selectedPaths.isEmpty { return [directory] }
        return visibleFolders.filter { selectedPaths.contains($0.path) }
    }

    static func resolvePath(_ text: String, relativeTo directory: URL) -> URL? {
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("file:") { return URL(string: text).flatMap { $0.isFileURL ? $0.standardizedFileURL : nil } }
        if text.contains("://") { return nil }
        let home = FileSystemService.realHomeDirectory().path
        let path = text == "~" ? home : text.hasPrefix("~/") ? home + String(text.dropFirst()) : text
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
    }

    nonisolated static func listFolders(_ directory: URL, showHidden: Bool) throws -> [URL] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(at: directory.standardizedFileURL.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey],
                                          options: showHidden ? [] : [.skipsHiddenFiles])
            .filter { url in
                var isDirectory: ObjCBool = false
                return url.pathExtension.lowercased() != "app"
                    && url.resolvingSymlinksInPath().pathExtension.lowercased() != "app"
                    && fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    && fm.isReadableFile(atPath: url.path)
            }
            // Foundation may resolve the parent (/tmp -> /private/tmp) while listing.
            // Keep the user's browsed path, including intentional directory symlinks.
            .map { directory.appendingPathComponent($0.lastPathComponent, isDirectory: true) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func openPath() {
        guard let target = Self.resolvePath(pathText, relativeTo: directory) else {
            errorMessage = L("folderPicker.invalid", "请选择可读取的本地文件夹。")
            return
        }
        navigate(to: target)
    }

    func navigate(to target: URL) {
        guard FSEngine.isSidebarFolder(target) else {
            errorMessage = L("folderPicker.invalid", "请选择可读取的本地文件夹。")
            return
        }
        loadTask?.cancel()
        let request = UUID()
        generation = request
        let target = target.standardizedFileURL
        let hidden = showHidden
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let resolved = target.resolvingSymlinksInPath()
                    let browsing = resolved.path == target.path ? target : resolved
                    return (browsing, try Self.listFolders(browsing, showHidden: hidden))
                }
            }.value
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.isLoading = false
            switch result {
            case .success(let listing):
                self.directory = listing.0
                self.pathText = listing.0.path
                self.folders = listing.1
                self.selectedPaths = []
                self.search = ""
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelLoading() { loadTask?.cancel(); generation = UUID() }
}
