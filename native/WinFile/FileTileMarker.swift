// 图标视图的磁贴标记
//
// 图标视图用的是 LazyVGrid，没有 NSTableView，因此无法用表格的 doubleAction。
// 这里给每个磁贴挂一个零尺寸的 AppKit 视图，记录它代表的项目与"打开"动作；
// 窗口级鼠标监听在识别到双击时，从这个标记取出项目并执行打开。
import AppKit
import SwiftUI

/// 承载磁贴身份与打开动作的标记视图。
///
/// 它**不参与命中测试**：单击选择、右键菜单仍由 SwiftUI 正常处理；
/// 双击则由窗口级鼠标监听按坐标查找它（用它的 frame 判断点是否落在磁贴上）。
/// 这样既拿到了磁贴位置，又不会抢走 SwiftUI 的交互。
final class FileTileMarkerView: NSView {
    var item: FileItem?
    var onActivate: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 把磁贴的项目与打开动作交给 AppKit 层
struct FileTileMarker: NSViewRepresentable {
    let item: FileItem
    let onActivate: () -> Void

    func makeNSView(context: Context) -> FileTileMarkerView {
        let view = FileTileMarkerView()
        view.item = item
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ view: FileTileMarkerView, context: Context) {
        view.item = item
        view.onActivate = onActivate
    }
}
