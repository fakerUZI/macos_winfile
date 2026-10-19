import AppKit
import SwiftUI

struct PaneResizeHandle: View {
    @Binding var preferredWidth: Double
    let actualWidth: CGFloat
    let range: ClosedRange<Double>
    let expandsToRight: Bool
    let title: String
    let defaultWidth: Double
    @State private var dragStart: Double?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Divider()
            ResizeCursorView()
        }
        .frame(width: PaneLayout.divider)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = actualWidth }
                preferredWidth = clamp((dragStart ?? actualWidth) + value.translation.width * (expandsToRight ? 1 : -1))
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) { preferredWidth = defaultWidth }
        .help(L("layout.resizeHint", "拖动调整宽度，双击恢复默认"))
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(L("layout.width", "%d 点", Int(actualWidth)))
        .accessibilityAdjustableAction { direction in
            preferredWidth = clamp(actualWidth + (direction == .increment ? 20 : -20))
        }
    }

    private func clamp(_ width: Double) -> Double { min(range.upperBound, max(range.lowerBound, width)) }
}

private struct ResizeCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class CursorView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
