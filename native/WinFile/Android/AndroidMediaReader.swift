import Foundation

struct AndroidMediaDescriptor {
    let entry: AndroidEntry
    let transport: String

    static func load(_ entry: AndroidEntry, cancellation: ScanCancellation) throws -> Self {
        guard AndroidOpenService.valid(entry) else { throw AndroidOpenError.invalidFile }
        let result = try MTPRunner.run("streamInfo", serial: entry.serial, path: entry.path, cancellation: cancellation)
        guard let live = try result.entry?.entry(serial: entry.serial), live.size > 0 else {
            throw AndroidOpenError.invalidFile
        }
        let transport = MTPRunner.attachmentID(serial: entry.serial)
        guard !transport.isEmpty else { throw MTPError.noDevice }
        return Self(entry: live, transport: transport)
    }

    func read(offset: Int64, count: Int, cancellation: ScanCancellation) throws -> Data {
        let result = try MTPRunner.run(
            "read", serial: entry.serial, path: entry.path,
            values: [
                "offset": offset, "length": count, "objectID": entry.objectID, "storageID": entry.storageID,
                "size": entry.size, "modified": Int64(entry.modified?.timeIntervalSince1970 ?? 0),
            ], cancellation: cancellation, expectedTransport: transport)
        guard let encoded = result.bytes, let bytes = Data(base64Encoded: encoded), bytes.count <= count else {
            throw MTPError.protocolError
        }
        return bytes
    }
}

/// Shared, bounded RAM only. A playback namespace cannot reuse another file/device's bytes.
final class AndroidMediaBuffer: @unchecked Sendable {
    static let shared = AndroidMediaBuffer(budget: 32 * 1024 * 1024)
    private struct Key: Hashable { let namespace: UUID; let offset: Int64 }
    private struct Block { let data: Data; var access: UInt64 }
    private let lock = NSLock()
    private var blocks: [Key: Block] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    let budget: Int
    init(budget: Int) { self.budget = max(0, budget) }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func get(_ namespace: UUID, offset: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(namespace: namespace, offset: offset)
        guard var block = blocks[key] else { return nil }
        clock &+= 1
        block.access = clock
        blocks[key] = block
        return block.data
    }

    func put(_ data: Data, namespace: UUID, offset: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count <= budget else { return }
        let key = Key(namespace: namespace, offset: offset)
        bytes -= blocks.removeValue(forKey: key)?.data.count ?? 0
        while bytes + data.count > budget, let oldest = blocks.min(by: { $0.value.access < $1.value.access }) {
            bytes -= oldest.value.data.count
            blocks.removeValue(forKey: oldest.key)
        }
        clock &+= 1
        blocks[key] = Block(data: data, access: clock)
        bytes += data.count
    }

    func remove(_ namespace: UUID) {
        lock.lock()
        defer { lock.unlock() }
        for key in blocks.keys.filter({ $0.namespace == namespace }) {
            bytes -= blocks.removeValue(forKey: key)?.data.count ?? 0
        }
    }
}

/// Reads at most one MiB per backend request. No temporary files or disk cache.
final class AndroidMediaReader: @unchecked Sendable {
    typealias Read = (Int64, Int, ScanCancellation) throws -> Data
    static let blockSize = 1024 * 1024
    let size: Int64
    let cancellation: ScanCancellation
    private let namespace = UUID()
    private let buffer: AndroidMediaBuffer
    private let backend: Read
    private let readLock = NSLock()
    private let cancellationLock = NSLock()
    private var activeRead: ScanCancellation?

    init(
        size: Int64, buffer: AndroidMediaBuffer = .shared, cancellation: ScanCancellation = ScanCancellation(),
        read: @escaping Read
    ) {
        self.size = size
        self.buffer = buffer
        self.cancellation = cancellation
        backend = read
    }

    convenience init(descriptor: AndroidMediaDescriptor, cancellation: ScanCancellation) {
        self.init(size: descriptor.entry.size, cancellation: cancellation, read: descriptor.read)
    }

    deinit { buffer.remove(namespace) }

    func cancel() {
        cancellation.cancel()
        cancellationLock.lock()
        activeRead?.cancel()
        cancellationLock.unlock()
        buffer.remove(namespace)
    }

    func read(offset: Int64, count: Int, requestCancellation: ScanCancellation? = nil) throws -> Data {
        func check() throws {
            if cancellation.isCancelled || requestCancellation?.isCancelled == true { throw CancellationError() }
        }
        guard size >= 0, offset >= 0, offset <= size, count >= 0, count <= Self.blockSize else {
            throw MTPError.operation("range")
        }
        while !readLock.try() {
            try check()
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { readLock.unlock() }
        try check()
        let readCancellation = requestCancellation ?? cancellation
        cancellationLock.lock()
        activeRead = readCancellation
        if cancellation.isCancelled { readCancellation.cancel() }
        cancellationLock.unlock()
        defer {
            cancellationLock.lock()
            activeRead = nil
            cancellationLock.unlock()
        }
        let end = offset + min(Int64(count), size - offset)
        var result = Data()
        var position = offset
        while position < end {
            try check()
            let start = position / Int64(Self.blockSize) * Int64(Self.blockSize)
            let expected = Int(min(Int64(Self.blockSize), size - start))
            let block: Data
            if let cached = buffer.get(namespace, offset: start) {
                block = cached
            } else {
                var fetched = Data()
                // Some phones return a short final block as a USB firmware workaround.
                while fetched.count < expected {
                    try check()
                    let data = try autoreleasepool {
                        try backend(start + Int64(fetched.count), expected - fetched.count, readCancellation)
                    }
                    try check()
                    guard !data.isEmpty, data.count <= expected - fetched.count else {
                        throw AndroidOpenError.incomplete
                    }
                    fetched.append(data)
                }
                try check()
                buffer.put(fetched, namespace: namespace, offset: start)
                // Cancel can race with put; ensure cancelled playback leaves no bytes behind.
                if cancellation.isCancelled { buffer.remove(namespace); throw CancellationError() }
                block = fetched
            }
            let from = Int(position - start)
            let length = min(Int(end - position), block.count - from)
            guard length > 0 else { throw AndroidOpenError.incomplete }
            result.append(block.subdata(in: from..<(from + length)))
            position += Int64(length)
        }
        try check()
        return result
    }
}
