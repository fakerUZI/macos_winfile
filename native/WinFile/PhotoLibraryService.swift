// 照片图库访问（Photos 框架）
//
// 为什么不直接读 ~/Pictures/Photos Library.photoslibrary：
//   1. 系统用 TCC 保护图库，第三方直接读文件会得到 "Operation not permitted"；
//   2. 图库内部是 SQLite + originals/UUID 文件，拿不到「相册」结构；
//   3. iCloud「优化存储」时原图可能不在本地。
// 因此统一走 PhotoKit：由系统负责授权、相册组织与 iCloud 按需下载。
import AppKit
import Foundation
import Photos

// MARK: - 数据模型

struct PhotoAlbum: Identifiable, Hashable {
    enum Kind: String {
        case allPhotos, favorites, videos, screenshots, user
    }

    let id: String
    let title: String
    let count: Int
    let kind: Kind
    let collection: PHAssetCollection

    var symbol: String {
        switch kind {
        case .allPhotos: return "photo.on.rectangle.angled"
        case .favorites: return "heart"
        case .videos: return "video"
        case .screenshots: return "camera.viewfinder"
        case .user: return "rectangle.stack"
        }
    }

    static func == (lhs: PhotoAlbum, rhs: PhotoAlbum) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PhotoAsset: Identifiable, Hashable {
    let asset: PHAsset

    var id: String { asset.localIdentifier }
    var isVideo: Bool { asset.mediaType == .video }
    var creationDate: Date? { asset.creationDate }
    var pixelWidth: Int { asset.pixelWidth }
    var pixelHeight: Int { asset.pixelHeight }

    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum PhotoExportError: LocalizedError {
    case noResource
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noResource:
            return L("photo.error.noResource", "这个项目没有可导出的原始文件。")
        case .writeFailed(let message):
            return L("photo.error.write", "导出失败：%@", message)
        }
    }
}

// MARK: - 服务

enum PhotoLibraryService {

    /// 读取相册列表：智能相册（所有照片/个人收藏/视频/截屏）+ 用户相册。
    /// PhotoKit 的 fetch 是线程安全的，可在后台队列调用。
    static func fetchAlbums() -> [PhotoAlbum] {
        var result: [PhotoAlbum] = []

        func addSmart(_ subtype: PHAssetCollectionSubtype, _ title: String, _ kind: PhotoAlbum.Kind) {
            let fetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                               subtype: subtype,
                                                               options: nil)
            fetch.enumerateObjects { collection, _, _ in
                result.append(PhotoAlbum(id: collection.localIdentifier,
                                         title: title,
                                         count: assetCount(in: collection),
                                         kind: kind,
                                         collection: collection))
            }
        }

        addSmart(.smartAlbumUserLibrary, L("photo.album.all", "所有照片"), .allPhotos)
        addSmart(.smartAlbumFavorites, L("photo.album.favorites", "个人收藏"), .favorites)
        addSmart(.smartAlbumVideos, L("photo.album.videos", "视频"), .videos)
        addSmart(.smartAlbumScreenshots, L("photo.album.screenshots", "截屏"), .screenshots)

        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album,
                                                                 subtype: .albumRegular,
                                                                 options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle ?? L("photo.album.untitled", "未命名相册")
            result.append(PhotoAlbum(id: collection.localIdentifier,
                                     title: title,
                                     count: assetCount(in: collection),
                                     kind: .user,
                                     collection: collection))
        }
        return result
    }

    /// 读取相册内的照片/视频，按创建时间倒序。
    static func fetchAssets(in album: PhotoAlbum) -> [PhotoAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(in: album.collection, options: options)
        var items: [PhotoAsset] = []
        items.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            items.append(PhotoAsset(asset: asset))
        }
        return items
    }

    private static func assetCount(in collection: PHAssetCollection) -> Int {
        let estimated = collection.estimatedAssetCount
        if estimated != NSNotFound { return estimated }
        return PHAsset.fetchAssets(in: collection, options: nil).count
    }

    /// 把原文件写到目录中，返回实际写入的 URL。
    ///
    /// 使用 PHAssetResourceManager 写出原始资源：保留 HEIC/JPEG/MP4 原格式，
    /// 且不需要把整幅图片解码进内存。
    static func export(_ item: PhotoAsset, to directory: URL) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: item.asset)
        guard !resources.isEmpty else { throw PhotoExportError.noResource }
        let resource = resources.sorted { rank($0.type) < rank($1.type) }.first ?? resources[0]

        let name = resource.originalFilename.isEmpty
            ? PhotoExportNaming.datedName(for: item.creationDate,
                                          extension: preferredExtension(for: resource.type),
                                          index: 0)
            : resource.originalFilename
        let target = PhotoExportNaming.uniqueURL(in: directory, preferredName: name)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) { error in
                if let error {
                    continuation.resume(throwing: PhotoExportError.writeFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        // 防御：PhotoKit 报告成功但文件不存在/为空时视为失败，避免静默丢文件。
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.fileExists(atPath: target.path), size > 0 else {
            throw PhotoExportError.writeFailed(L("photo.error.empty", "写入后文件不存在或为空。"))
        }
        return target
    }

    /// 资源优先级：优先可编辑后的全尺寸版本，其次原始版本。
    private static func rank(_ type: PHAssetResourceType) -> Int {
        switch type {
        case .fullSizePhoto: return 0
        case .photo: return 1
        case .fullSizeVideo: return 2
        case .video: return 3
        case .pairedVideo: return 4
        case .alternatePhoto: return 5
        case .adjustmentData: return 8
        case .adjustmentBasePhoto: return 9
        default: return 6
        }
    }

    private static func preferredExtension(for type: PHAssetResourceType) -> String {
        switch type {
        case .video, .fullSizeVideo, .pairedVideo: return "mov"
        default: return "jpg"
        }
    }
}

// MARK: - 缩略图

/// 缩略图缓存：同一张照片在滚动时只请求一次。
@MainActor
final class PhotoThumbnails {
    static let shared = PhotoThumbnails()

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, NSImage>()

    func image(for asset: PHAsset, pixelSize: CGSize) async -> NSImage? {
        let key = "\(asset.localIdentifier)|\(Int(pixelSize.width))x\(Int(pixelSize.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast

        let box = ResumeBox()
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset,
                                 targetSize: pixelSize,
                                 contentMode: .aspectFill,
                                 options: options) { image, _ in
                // PhotoKit 在部分情况下会回调多次（降级图 → 高清图），只取第一次结果。
                guard box.claim() else { return }
                if let image { self.cache.setObject(image, forKey: key) }
                continuation.resume(returning: image)
            }
        }
    }

    /// 线程安全的一次性标记
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
