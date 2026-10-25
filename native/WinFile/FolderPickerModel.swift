import AppKit
import Combine
import Darwin
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
    @Published private(set) var isCreating = false
    @Published private(set) var canChooseDirectory = false
    @Published var errorMessage: String?
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?

    var isWorking: Bool { isLoading || isCreating }
    var canCreateFolder: Bool { canChooseDirectory && !isWorking && FileManager.default.isWritableFile(atPath: directory.path) }

    init(initialDirectory: URL?) {
        let home = FileSystemService.realHomeDirectory()
        directory = initialDirectory.flatMap { $0.isFileURL ? $0 : nil } ?? home
        pathText = directory.path
    }

    var visibleFolders: [URL] {
        folders.filter { search.isEmpty || $0.lastPathComponent.localizedStandardContains(search) }
    }

    var candidates: [URL] {
        if selectedPaths.isEmpty { return [directory] }
        return visibleFolders.filter { selectedPaths.contains($0.path) }
    }

    nonisolated static func resolvePath(_ text: String, relativeTo directory: URL) -> URL? {
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

    /// mkdir is atomic: an existing directory, file or link is a conflict, never
    /// a successful creation. Names cannot escape the currently browsed folder.
    nonisolated static func createFolder(in directory: URL, named rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.isFileURL, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0"),
              (name as NSString).pathExtension.lowercased() != "app" else { throw FSError.invalidName }
        let target = directory.appendingPathComponent(name, isDirectory: true)
        let failure = target.withUnsafeFileSystemRepresentation { path -> Int32? in
            guard let path else { return EINVAL }
            return Darwin.mkdir(path, 0o755) == 0 ? nil : errno
        }
        if let code = failure {
            if code == EEXIST { throw FSError.nameExists(name) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: target.path])
        }
        return target
    }

    /// Only navigate after a successful creation for the same browsing request.
    /// Dismissing or navigating while a worker finishes cannot reopen the picker.
    func createFolder(named name: String) async -> Bool {
        guard canChooseDirectory, !isWorking else { return false }
        let parent = directory
        let request = generation
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Self.createFolder(in: parent, named: name) }
        }.value
        guard generation == request else { return false }
        switch result {
        case .success(let created):
            navigate(to: created)
            return true
        case .failure(let error):
            errorMessage = error.localizedDescription
            return false
        }
    }

    func navigate(to target: URL) {
        guard target.isFileURL, target.pathExtension.lowercased() != "app" else {
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
                    guard FSEngine.isSidebarFolder(target) else { throw FSError.notAuthorized(target) }
                    let resolved = target.resolvingSymlinksInPath()
                    let browsing = resolved.path == target.path ? target : resolved
                    return (browsing, try Self.listFolders(browsing, showHidden: hidden))
                }
            }.value
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.isLoading = false
            switch result {
            case .success(let listing):
                self.canChooseDirectory = true
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

/// A folder-only request owned by the initiating model/window.
struct FolderPickerRequest: Identifiable {
    let id = UUID()
    let title: String
    let initialDirectory: URL?
    let onSelect: (URL) -> Void
}
