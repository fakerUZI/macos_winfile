import AppKit
import QuickLookThumbnailing

struct ImageBox: @unchecked Sendable {
    let image: NSImage?
}

/// Bounded, coalesced thumbnail requests. Each visible tile owns a cancellable waiter;
/// scrolling away cancels Quick Look only after the final consumer leaves.
actor ThumbnailService {
    static let shared = ThumbnailService()
    struct Statistics { let bytes: Int; let cached: Int; let running: Int; let queued: Int }
    private struct Entry { let image: NSImage; let cost: Int; var used: UInt64 }
    private struct Job {
        let id = UUID()
        let url: URL
        let pixels: Int
        var waiters: [UUID: CheckedContinuation<ImageBox, Never>] = [:]
        var task: Task<Void, Never>?
    }
    private let byteLimit: Int
    private let concurrencyLimit: Int
    private let generator: @Sendable (URL, Int) async -> ImageBox
    private var cache: [String: Entry] = [:]
    private var jobs: [String: Job] = [:]
    private var queue: [(String, UUID)] = []
    private var bytes = 0
    private var running = 0
    private var clock: UInt64 = 0
    private var pressure: DispatchSourceMemoryPressure?

    init(byteLimit: Int = 64 * 1024 * 1024, concurrencyLimit: Int = 4,
         generator: @escaping @Sendable (URL, Int) async -> ImageBox = { url, pixels in
             await ThumbnailService.generate(url: url, pixels: pixels)
         }) {
        self.byteLimit = max(0, byteLimit)
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.generator = generator
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure = source
        source.setEventHandler { [weak self] in Task { await self?.removeCachedImages() } }
        source.resume()
    }
    deinit { pressure?.cancel() }

    func statistics() -> Statistics {
        Statistics(bytes: bytes, cached: cache.count, running: running, queued: jobs.values.filter { $0.task == nil }.count)
    }
    func removeCachedImages() { cache.removeAll(); bytes = 0 }

    func thumbnail(for url: URL, size: CGFloat, version: String = "") async -> ImageBox {
        guard !Task.isCancelled else { return ImageBox(image: nil) }
        let pixels = max(1, min(2048, Int(size * 2)))
        let key = "\(url.path)|\(pixels)|\(version)"
        clock &+= 1
        if var entry = cache[key] {
            entry.used = clock; cache[key] = entry
            return ImageBox(image: entry.image)
        }
        let waiter = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: ImageBox(image: nil)); return }
                if jobs[key] == nil {
                    let job = Job(url: url, pixels: pixels)
                    jobs[key] = job
                    queue.append((key, job.id))
                }
                jobs[key]?.waiters[waiter] = continuation
                startQueuedJobs()
            }
        }, onCancel: { Task { await self.cancel(key: key, waiter: waiter) } })
    }

    private func cancel(key: String, waiter: UUID) {
        guard var job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: ImageBox(image: nil))
        if job.waiters.isEmpty {
            jobs.removeValue(forKey: key)
            job.task?.cancel()
            queue.removeAll { $0.0 == key && $0.1 == job.id }
        } else { jobs[key] = job }
    }
    private func startQueuedJobs() {
        while running < concurrencyLimit, !queue.isEmpty {
            let (key, id) = queue.removeFirst()
            guard var job = jobs[key], job.id == id, !job.waiters.isEmpty else { continue }
            running += 1
            let generate = generator, url = job.url, pixels = job.pixels
            job.task = Task {
                let box = await generate(url, pixels)
                finish(key: key, id: id, box: Task.isCancelled ? ImageBox(image: nil) : box)
            }
            jobs[key] = job
        }
    }
    private func finish(key: String, id: UUID, box: ImageBox) {
        running -= 1
        if let job = jobs[key], job.id == id {
            jobs.removeValue(forKey: key)
            if let image = box.image {
                let cost = image.representations.reduce(1024) { total, rep in
                    total + max(1, rep.pixelsWide) * max(1, rep.pixelsHigh) * 4
                }
                if cost <= byteLimit {
                    while bytes + cost > byteLimit || cache.count >= 800 {
                        guard let oldest = cache.min(by: { $0.value.used < $1.value.used }) else { break }
                        bytes -= oldest.value.cost; cache.removeValue(forKey: oldest.key)
                    }
                    clock &+= 1
                    cache[key] = Entry(image: image, cost: cost, used: clock); bytes += cost
                }
            }
            for continuation in job.waiters.values { continuation.resume(returning: box) }
        }
        startQueuedJobs()
    }
    private static func generate(url: URL, pixels: Int) async -> ImageBox {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels),
                                                  scale: 1, representationTypes: .thumbnail)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    // One bitmap representation, rather than retaining a large multi-resolution NSImage.
                    continuation.resume(returning: ImageBox(image: rep.map {
                        NSImage(cgImage: $0.cgImage, size: CGSize(width: pixels, height: pixels))
                    }))
                }
                if Task.isCancelled { QLThumbnailGenerator.shared.cancel(request) }
            }
        }, onCancel: { QLThumbnailGenerator.shared.cancel(request) })
    }
}
