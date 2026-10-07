// 支持闭包动作的菜单项（NSMenu 默认需要 target/selector）
import AppKit

final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("不支持 NSCoder") }

    @objc private func invoke() { closure() }
}
