import AppKit

/// System icons use the same bounded, coalesced image pipeline as thumbnails.
/// Keep a separate budget so media previews cannot evict every file icon.
enum FileIconService {
    static let shared = ThumbnailService(byteLimit: 12 * 1024 * 1024, concurrencyLimit: 2,
                                         generator: { url, pixels in
        await Task.detached(priority: .utility) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            var bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            let compact = icon.cgImage(forProposedRect: &bounds, context: nil, hints: nil).map {
                NSImage(cgImage: $0, size: NSSize(width: pixels, height: pixels))
            }
            return ImageBox(image: compact ?? icon)
        }.value
    })
}
