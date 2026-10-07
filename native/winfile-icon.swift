// winfile-icon: 用 NSWorkspace 提取任意文件/应用的真实图标
// （支持只有 Assets.car 的系统应用；并强制使用最大可用表示，避免放大小图导致模糊）
// 用法: winfile-icon <路径> [尺寸] [--scale N]   向标准输出写 PNG 数据
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: winfile-icon <path> [size] [--scale N]\n".data(using: .utf8)!)
    exit(2)
}
let path = args[1]

var requested = 128
var scale = 1
var index = 2
while index < args.count {
    switch args[index] {
    case "--scale":
        if index + 1 < args.count, let value = Int(args[index + 1]) { scale = max(1, min(value, 4)) }
        index += 2
    default:
        if let value = Int(args[index]) { requested = max(16, min(value, 1024)) }
        index += 1
    }
}

/// 在给定的 NSImage 表示中挑出最大的像素副本，确保缩放时来源足够清晰
func bestRepresentation(of image: NSImage) -> NSBitmapImageRep? {
    var candidates: [NSBitmapImageRep] = []
    if let reps = image.representations as? [NSBitmapImageRep] {
        candidates = reps
    }
    // 兜底：从 TIFF 里再找一次
    if candidates.isEmpty, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        candidates = [rep]
    }
    return candidates.max { lhs, rhs in
        (lhs.pixelsWide * lhs.pixelsHigh) < (rhs.pixelsWide * rhs.pixelsHigh)
    }
}

let source = NSWorkspace.shared.icon(forFile: path)
let pixels = requested * scale
let side = CGFloat(pixels)

/// 把一张位图绘制到精确像素尺寸的新位图里
func normalize(_ rep: NSBitmapImageRep, _ pixels: Int) -> NSBitmapImageRep? {
    guard let finalRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: finalRep)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return finalRep
}

func emit(_ rep: NSBitmapImageRep) -> Never {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("无法编码 PNG: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardOutput.write(png)
    exit(0)
}

// 快路径：系统已提供足够大的位图表示时，直接缩放，避免 AppKit 先渲染超大图（慢数十倍）
if let best = bestRepresentation(of: source) {
    let longest = max(best.pixelsWide, best.pixelsHigh)
    if longest >= pixels {
        if longest == pixels, let exact = normalize(best, pixels) {
            emit(exact)
        }
        if let scaled = normalize(best, pixels) {
            emit(scaled)
        }
    }
}

// 慢路径：只有矢量/小图表示，需让 AppKit 按目标尺寸重绘
source.size = NSSize(width: side, height: side)
let target = NSImage(size: NSSize(width: side, height: side))
target.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.shouldAntialias = true
source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
target.unlockFocus()

guard let tiff = target.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let final = normalize(rep, pixels) else {
    FileHandle.standardError.write("无法生成图标: \(path)\n".data(using: .utf8)!)
    exit(1)
}
emit(final)

