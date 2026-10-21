// 照片图库页面的状态
//
// 只负责：授权状态、相册与资源加载、选择、导出/打开。
// 所有 PhotoKit 读取都在后台执行，主线程只更新 @Published 状态。
import AppKit
import Combine
import Foundation
import Photos

@MainActor
final class PhotoLibraryModel: ObservableObject {

    enum Access: Equatable {
        case checking
        case needsPermission
        case granted
        case limited
        case denied
    }

    @Published private(set) var access: Access = .checking
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var selectedAlbumID: String?
    @Published var selection: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: String?
    @Published var message: String?

    private var hasStarted = false

    var selectedAlbum: PhotoAlbum? {
        albums.first { $0.id == selectedAlbumID }
    }

    var selectedAssets: [PhotoAsset] {
        assets.filter { selection.contains($0.id) }
    }

    // MARK: - 生命周期

    /// 首次进入页面时调用：检查/请求授权并加载相册。
    func activate() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refreshAccess(requestIfNeeded: true)
    }

    /// 用户点「允许访问照片」或从系统设置返回后调用。
    func retryAccess() async {
        await refreshAccess(requestIfNeeded: true)
    }

    /// 从系统设置改过权限后，重新检查并加载。
    func reloadAfterSettingsChange() async {
        await refreshAccess(requestIfNeeded: false)
    }

    private func refreshAccess(requestIfNeeded: Bool) async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, requestIfNeeded {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch status {
        case .authorized:
            access = .granted
        case .limited:
            access = .limited
        case .denied, .restricted:
            access = .denied
        case .notDetermined:
            access = .needsPermission
        @unknown default:
            access = .denied
        }
        guard access == .granted || access == .limited else { return }
        await reloadAlbums()
    }

    // MARK: - 加载

    func reload() async {
        await reloadAlbums()
    }

    private func reloadAlbums() async {
        isLoading = true
        let fetched = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.fetchAlbums()
        }.value
        albums = fetched
        if let current = selectedAlbumID, fetched.contains(where: { $0.id == current }) {
            // 保持当前相册
        } else {
            selectedAlbumID = fetched.first?.id
        }
        isLoading = false
        await reloadAssets()
    }

    func select(albumID: String) async {
        guard albumID != selectedAlbumID else { return }
        selectedAlbumID = albumID
        selection = []
        await reloadAssets()
    }

    private func reloadAssets() async {
        guard let album = selectedAlbum else {
            assets = []
            return
        }
        isLoading = true
        let fetched = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.fetchAssets(in: album)
        }.value
        assets = fetched
        let valid = Set(fetched.map(\.id))
        selection = selection.intersection(valid)
        isLoading = false
    }

    // MARK: - 选择

    func toggle(_ item: PhotoAsset, extend: Bool) {
        if extend {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else {
            selection = [item.id]
        }
    }

    func selectAll() {
        selection = Set(assets.map(\.id))
    }

    func clearSelection() {
        selection = []
    }

    // MARK: - 导出与打开

    /// 导出所选项目到目录；逐个写出原文件并报告进度。
    func exportSelection(to directory: URL) {
        let chosen = selectedAssets
        guard !chosen.isEmpty, !isExporting else { return }
        isExporting = true
        message = nil
        exportProgress = L("photo.export.progress", "已导出 %d / %d", 0, chosen.count)

        Task { [weak self] in
            var succeeded: [URL] = []
            var failures: [String] = []
            for (index, item) in chosen.enumerated() {
                do {
                    let url = try await PhotoLibraryService.export(item, to: directory)
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
                    TabDiagnostics.shared.record("photo.export.ok",
                        detail: "目标=\(url.path) 存在=\(exists) 大小=\(size.map(String.init) ?? "-")")
                    succeeded.append(url)
                } catch {
                    TabDiagnostics.shared.record("photo.export.error",
                        detail: "\(error.localizedDescription)")
                    failures.append(error.localizedDescription)
                }
                await MainActor.run { [weak self] in
                    self?.exportProgress = L("photo.export.progress", "已导出 %d / %d",
                                             index + 1, chosen.count)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isExporting = false
                self.exportProgress = nil
                if failures.isEmpty {
                    self.message = L("photo.export.done", "已导出 %d 个文件到「%@」",
                                     succeeded.count, directory.lastPathComponent)
                } else {
                    self.message = L("photo.export.partial", "已导出 %d 个，%d 个失败：%@",
                                     succeeded.count, failures.count,
                                     failures.first ?? "")
                }
            }
        }
    }

    /// 导出单个项目到临时目录，再用默认应用打开。
    func open(_ item: PhotoAsset) {
        Task { [weak self] in
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("WinFile-Photos", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = try await PhotoLibraryService.export(item, to: directory)
                await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.message = error.localizedDescription
                }
            }
        }
    }

    func revealExported(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// 打开系统设置中的「照片」隐私面板
    func openPrivacySettings() {
        let string = "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
