// 图片缩略图
//
// 用 QuickLook 生成（系统统一路径，支持 HEIC/RAW 等格式，内存占用可控），
// 而不是直接解码原图 —— 大图直接解码会把整幅位图读进内存。
// 结果按「路径 + 目标尺寸」缓存，滚动时不重复生成。
import AppKit
import QuickLookThumbnailing

/// NSImage 未声明 Sendable，但缩略图/图标生成后只读、跨线程传递安全，
/// 用它包裹以满足 Swift 6 并发检查。
struct ImageBox: @unchecked Sendable {
    let image: NSImage?
}

actor ThumbnailService {

    static let shared = ThumbnailService()

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<ImageBox, Never>] = [:]

    /// 生成（或取缓存）缩略图
    /// - Parameters:
    ///   - url: 图片路径
    ///   - size: 目标显示尺寸（pt）
    func thumbnail(for url: URL, size: CGFloat) async -> ImageBox {
        // 以像素为单位请求，适配 Retina
        let pixels = Int(size * 2)
        let key = "\(url.path)|\(pixels)"
        if let cached = cache[key] { return ImageBox(image: cached) }
        if let running = inFlight[key] { return await running.value }

        let task = Task<ImageBox, Never> { [url] in
            ImageBox(image: await Self.generate(url: url, pixels: pixels))
        }
        inFlight[key] = task
        let box = await task.value
        inFlight[key] = nil
        if let image = box.image {
            cache[key] = image
            // 简单的容量控制：缓存过多时清空（缩略图可随时重建）
            if cache.count > 1200 { cache.removeAll(keepingCapacity: true) }
        }
        return box
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

}
