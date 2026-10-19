import Foundation
import Darwin

/// Watch entry changes in the current folder. Caller debounces and revalidates its navigation state.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    init?(directory: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link], queue: .global(qos: .utility))
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    deinit { source.cancel() }
}
