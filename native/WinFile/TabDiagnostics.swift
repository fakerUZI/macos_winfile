// 页签交互诊断：记录点击与状态变更，便于定位「点了没反应」这类问题
import Foundation

@MainActor
final class TabDiagnostics {
    static let shared = TabDiagnostics()
    static let recordsViewRendering = CommandLine.arguments.contains("--selftest-tabs")
        || ProcessInfo.processInfo.environment["WINFILE_TAB_DEBUG"] == "1"
    private nonisolated static let diskQueue = DispatchQueue(label: "WinFile.TabDiagnostics", qos: .utility)

    /// 系统事件和过渡布局可能包含 NaN、无穷或超出 Int 范围的值；诊断不可改变程序行为。
    static func coordinate(_ value: CGFloat) -> String {
        String(describing: value)
    }

    /// Keep the actionable error chain, without dumping arbitrary userInfo or file contents.
    nonisolated static func fileErrorDetail(_ error: Error, operation: String, url: URL) -> String {
        func singleLine(_ text: String) -> String {
            text.replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path == home ? "~" : url.path.hasPrefix(home + "/")
            ? "~" + String(url.path.dropFirst(home.count)) : url.path
        var parts = ["operation=\(singleLine(operation))", "path=\(singleLine(path))"]
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        for depth in 0..<8 {
            guard let entry = current, seen.insert(ObjectIdentifier(entry)).inserted else { break }
            parts.append("error[\(depth)]=\(singleLine(entry.domain)) code=\(entry.code) message=\(singleLine(entry.localizedDescription))")
            current = entry.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " | ")
    }

    func recordFileError(_ error: Error, operation: String, url: URL) {
        record("filesystem.error", detail: Self.fileErrorDetail(error, operation: operation, url: url))
    }

    /// 实时落盘的诊断文件（便于"你点几下、我读文件"这种协作排查）
    nonisolated static var liveURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".winfile-mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tab-diagnostics.log")
    }

    private var entries: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func record(_ event: String, detail: String = "") {
        let line = "[\(formatter.string(from: Date()))] \(event)\(detail.isEmpty ? "" : " | \(detail)")"
        entries.append(line)
        if entries.count > 2000 { entries.removeFirst(500) }
        // Never wait for filesystem I/O from a click handler or view body.
        Self.diskQueue.async { Self.appendLineToDisk(line) }
        if ProcessInfo.processInfo.environment["WINFILE_TAB_DEBUG"] == "1" {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    private nonisolated static func appendLineToDisk(_ line: String) {
        let url = TabDiagnostics.liveURL
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func write(to path: String) {
        let text = entries.isEmpty ? "（没有记录到任何页签交互事件）" : entries.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func flush() { Self.diskQueue.sync {} }

    func clearPersistedLog() {
        entries.removeAll()
        Self.diskQueue.async { try? FileManager.default.removeItem(at: Self.liveURL) }
        record("diagnostics.cleared")
    }

    func clear() { entries.removeAll() }
}
