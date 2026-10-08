// 图片缩略图
//
// 用 QuickLook 生成（系统统一路径，支持 HEIC/RAW 等格式，内存占用可控），
// 而不是直接解码原图 —— 大图直接解码会把整幅位图读进内存。
// 结果按「路径 + 目标尺寸」缓存，滚动时不重复生成。
import AppKit
import QuickLookThumbnailing

actor ThumbnailService {

    static let shared = ThumbnailService()

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// 生成（或取缓存）缩略图
    /// - Parameters:
    ///   - url: 图片路径
    ///   - size: 目标显示尺寸（pt）
    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        // 以像素为单位请求，适配 Retina
        let pixels = Int(size * 2)
        let key = "\(url.path)|\(pixels)"
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<NSImage?, Never> { [url] in
            await Self.generate(url: url, pixels: pixels)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache[key] = image
            // 简单的容量控制：缓存过多时清空（缩略图可随时重建）
            if cache.count > 1200 { cache.removeAll(keepingCapacity: true) }
        }
        return image
    }

    private static func generate(url: URL, pixels: Int) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixels, height: pixels),
            scale: 1,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }

    /// 清空缓存（切换目录等场景可调用）
    func clear() { cache.removeAll(); }
}
