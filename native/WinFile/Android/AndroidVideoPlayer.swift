import AppKit
import AVFoundation
import AVKit
import Combine
import UniformTypeIdentifiers

/// Custom-scheme asset data is supplied from MTP/RAM, without a local HTTP server
/// or a file URL that would require materializing a complete video on disk.
final class AndroidVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "WinFile.MTP.VideoRequests")
    private let work = DispatchQueue(label: "WinFile.MTP.VideoReads", qos: .userInitiated)
    private let reader: AndroidMediaReader
    private let contentType: String
    private let onFailure: ((Error) -> Void)?
    private var pending: [ObjectIdentifier: (AVAssetResourceLoadingRequest, ScanCancellation)] = [:]
    private var stopped = false

    init(reader: AndroidMediaReader, filename: String, onFailure: ((Error) -> Void)? = nil) {
        self.reader = reader
        self.onFailure = onFailure
        contentType =
            UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier ?? UTType.movie.identifier
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !stopped, !reader.cancellation.isCancelled, pending.count < 8 else {
            request.finishLoading(with: CancellationError())
            return true
        }
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = reader.size
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { request.finishLoading(); return true }
        let start = max(data.requestedOffset, data.currentOffset)
        let (requestedEnd, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
        guard start >= 0, start <= reader.size,
            data.requestsAllDataToEndOfResource || (data.requestedLength >= 0 && !overflow && requestedEnd >= start)
        else {
            request.finishLoading(with: MTPError.operation("range"))
            return true
        }
        let end = data.requestsAllDataToEndOfResource ? reader.size : min(requestedEnd, reader.size)
        let id = ObjectIdentifier(request), token = ScanCancellation()
        pending[id] = (request, token)
        work.async { [self] in
            var offset = start
            do {
                while offset < end {
                    if token.isCancelled { throw CancellationError() }
                    let bytes = try reader.read(
                        offset: offset, count: Int(min(Int64(AndroidMediaReader.blockSize), end - offset)),
                        requestCancellation: token)
                    let delivered = queue.sync { () -> Bool in
                        guard pending[id] != nil, !token.isCancelled, !stopped else { return false }
                        request.dataRequest?.respond(with: bytes)
                        return true
                    }
                    if !delivered { throw CancellationError() }
                    offset += Int64(bytes.count)
                }
                queue.async { [self] in
                    guard pending.removeValue(forKey: id) != nil else { return }
                    request.finishLoading()
                }
            } catch {
                queue.async { [self] in
                    guard pending.removeValue(forKey: id) != nil else { return }
                    request.finishLoading(with: error)
                    if !(error is CancellationError), !stopped { onFailure?(error) }
                }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeValue(forKey: ObjectIdentifier(request))?.1.cancel()
    }

    func invalidate(error: Error = CancellationError()) {
        reader.cancel()
        queue.async { [self] in
            stopped = true
            for (request, token) in pending.values {
                token.cancel()
                request.finishLoading(with: error)
            }
            pending.removeAll()
        }
    }
}

@MainActor
final class AndroidVideoPlayer: NSObject, NSWindowDelegate {
    static let shared = AndroidVideoPlayer()
    private var window: NSWindow?
    private var player: AVPlayer?
    private var asset: AVURLAsset?
    private var loader: AndroidVideoResourceLoader?
    private var statusObservation: NSKeyValueObservation?
    private var deviceObservation: AnyCancellable?
    private var statusLabel: NSTextField?
    private var openingID = UUID()
    private var openingCancellation: ScanCancellation?

    static func handles(_ entry: AndroidEntry) -> Bool {
        FileTypeDB.info(name: entry.name, isDirectory: entry.isDirectory, isSymlink: false, isBundle: false).category
            == .video
    }

    func open(_ entry: AndroidEntry, preview: Bool, cancellation: ScanCancellation) async throws {
        close()
        let id = UUID()
        openingID = id
        openingCancellation = cancellation
        let prepared = try await Task.detached(priority: .userInitiated) {
            let descriptor = try AndroidMediaDescriptor.load(entry, cancellation: cancellation)
            let reader = AndroidMediaReader(descriptor: descriptor, cancellation: cancellation)
            _ = try reader.read(offset: 0, count: 1)
            // MP4 indexes can be at the end. Probe large-file addressing before opening.
            if descriptor.entry.size > Int64(UInt32.max) {
                _ = try reader.read(offset: descriptor.entry.size - 1, count: 1)
            }
            return (descriptor, reader)
        }.value
        guard openingID == id, !cancellation.isCancelled, !Task.isCancelled else {
            prepared.1.cancel(); throw CancellationError()
        }
        openingCancellation = nil
        let (descriptor, reader) = prepared
        let resourceLoader = AndroidVideoResourceLoader(reader: reader, filename: entry.name) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.openingID == id, self.window != nil else { return }
                self.player?.pause()
                self.loader?.invalidate()
                self.statusLabel?.stringValue = error.localizedDescription
            }
        }
        let url = URL(
            string: "winfile-mtp-video://\(UUID().uuidString)/video.\((entry.name as NSString).pathExtension)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.queue)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        let player = AVPlayer(playerItem: item)
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(
            wrappingLabelWithString: L("android.stream.memory", "MTP 流式播放 · 共享内存缓存上限 32 MiB · 不保存完整视频副本"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(view)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = entry.name
        window.contentView = content
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        self.window = window
        self.player = player
        self.asset = asset
        loader = resourceLoader
        statusLabel = label
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                self.loader?.invalidate()
                self.statusLabel?.stringValue = L(
                    "android.stream.failed", "无法流式播放此视频，可能是编码或设备读取不兼容。未自动下载；如需外部播放器，请手动下载。")
                TabDiagnostics.shared.record("mtp.video.failed", detail: "code=\((item.error as NSError?)?.code ?? 0)")
            }
        }
        deviceObservation = AndroidDeviceRegistry.shared.$devices.sink { [weak self] devices in
            guard let self,
                !devices.contains(where: {
                    $0.serial == entry.serial && $0.isReady && $0.transportID == descriptor.transport
                })
            else { return }
            self.player?.pause()
            self.loader?.invalidate(error: MTPError.noDevice)
            self.statusLabel?.stringValue = L("android.stream.disconnected", "设备连接已变化，已停止播放并释放内存缓存。请从侧边栏重新打开视频。")
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        if !preview { player.play() }
        TabDiagnostics.shared.record("mtp.video.open", detail: "mode=memory size=\(descriptor.entry.size)")
    }

    func windowWillClose(_ notification: Notification) { stop() }

    func close() {
        openingID = UUID()
        openingCancellation?.cancel()
        openingCancellation = nil
        window?.close()
        stop()
    }

    private func stop() {
        player?.pause()
        loader?.invalidate()
        asset?.cancelLoading()
        player?.replaceCurrentItem(with: nil)
        statusObservation = nil
        deviceObservation = nil
        window = nil
        player = nil
        asset = nil
        loader = nil
        statusLabel = nil
    }
}
