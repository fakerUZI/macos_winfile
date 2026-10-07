// 无障碍树探针：读取真实渲染出的可访问元素与文本（比像素可靠）
import AppKit
import Foundation

@MainActor
enum A11yProbe {

    /// 收集窗口内所有可访问元素的描述文本
    static func collectLabels(from element: Any, depth: Int = 0, into result: inout [String]) {
        guard depth < 40 else { return }
        guard let object = element as? NSObject else { return }
        if object.responds(to: NSSelectorFromString("accessibilityRole")) {
            let role = (object.value(forKey: "accessibilityRole") as? String) ?? ""
            let label = (object.value(forKey: "accessibilityLabel") as? String) ?? ""
            let value = (object.value(forKey: "accessibilityValue") as? String) ?? ""
            let title = (object.value(forKey: "accessibilityTitle") as? String) ?? ""
            let text = [label, value, title].first(where: { !$0.isEmpty }) ?? ""
            if !text.isEmpty {
                result.append("[\(role)] \(text)")
            }
        }
        if object.responds(to: NSSelectorFromString("accessibilityChildren")),
           let children = object.value(forKey: "accessibilityChildren") as? [Any] {
            for child in children {
                collectLabels(from: child, depth: depth + 1, into: &result)
            }
        }
    }

    static func dump(to path: String) -> [String] {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else {
            return ["没有窗口"]
        }
        var labels: [String] = []
        collectLabels(from: window, into: &labels)
        let text = labels.joined(separator: "\n")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return labels
    }

    /// 找出疑似"面包屑/地址栏"的文本元素（用于验证导航后是否更新）
    static func breadcrumbLikeLabels() -> [String] {
        let labels = dump(to: "/dev/null")
        // 面包屑通常是路径片段：启动磁盘名、个人文件夹、目录名等短文本
        return labels.filter { line in
            line.contains("Macintosh") || line.contains("个人文件夹")
                || line.contains("主页") || line.contains("此电脑")
                || line.contains("地址栏") || line.contains("目录名称")
        }
    }
}
