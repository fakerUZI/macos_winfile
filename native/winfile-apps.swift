// winfile-apps: 用 Launch Services 查询「用什么应用打开这个文件」
// 输出 JSON: {default, default_name, bundle_id, apps:[路径...]}
// 用法: winfile-apps <文件路径> [--limit N]
import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: winfile-apps <path> [--limit N]\n".data(using: .utf8)!)
    exit(2)
}
let path = args[1]
var limit = 40
if let idx = args.firstIndex(of: "--limit"), idx + 1 < args.count, let value = Int(args[idx + 1]) {
    limit = max(1, min(value, 200))
}

let url = URL(fileURLWithPath: path) as CFURL
var payload: [String: Any] = ["default": "", "default_name": "", "bundle_id": "", "apps": []]

func bundleID(of appURL: URL) -> String {
    Bundle(url: appURL)?.bundleIdentifier ?? ""
}

// 默认打开方式（可能为空：没有关联应用）
var defaultURL: URL?
if let unmanaged = LSCopyDefaultApplicationURLForURL(url, .all, nil) {
    defaultURL = unmanaged.takeRetainedValue() as URL
}

var ordered: [URL] = []
var seen = Set<String>()
func add(_ candidate: URL?) {
    guard let candidate else { return }
    let standardized = candidate.standardizedFileURL
    let key = standardized.path
    guard !seen.contains(key) else { return }
    seen.insert(key)
    ordered.append(standardized)
}
add(defaultURL)

// 所有可打开该文件的应用
if let unmanaged = LSCopyApplicationURLsForURL(url, .all) {
    if let list = unmanaged.takeRetainedValue() as? [URL] {
        for item in list { add(item) }
    }
}

payload["apps"] = ordered.prefix(limit).map { $0.path }
if let fallback = ordered.first {
    payload["default"] = fallback.path
    let bundle = Bundle(url: fallback)
    payload["default_name"] = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? fallback.deletingPathExtension().lastPathComponent
    payload["bundle_id"] = bundleID(of: fallback)
} else if let type = UTType(filenameExtension: (path as NSString).pathExtension)?.identifier,
          let unmanaged = LSCopyDefaultApplicationURLForContentType(type as CFString, .all, nil) {
    let app = unmanaged.takeRetainedValue() as URL
    payload["default"] = app.path
    payload["default_name"] = (Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? app.deletingPathExtension().lastPathComponent
    payload["bundle_id"] = bundleID(of: app)
    payload["apps"] = [app.path]
}

guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
    FileHandle.standardError.write("无法序列化结果\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardOutput.write(data)
