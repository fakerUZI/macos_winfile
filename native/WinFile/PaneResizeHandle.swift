import AppKit
import SwiftUI

struct PaneResizeHandle: View {
    @Binding var preferredWidth: Double
    let actualWidth: CGFloat
    let range: ClosedRange<Double>
    let expandsToRight: Bool
    let title: String
    let defaultWidth: Double
    let collapseTitle: String
    let collapse: () -> Void
    @State private var dragStart: Double?

    var body: some View {
        ZStack {
            PaneDividerSurface()
                .help(L("layout.resizeHint", "拖动调整宽度，双击恢复默认"))
            ResizeCursorView()
            PaneToggleButton(pointsLeft: expandsToRight, title: collapseTitle,
                             identifier: expandsToRight ? "sidebar.collapse" : "inspector.collapse",
                             action: collapse)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(L("layout.width", "%d 点", Int(actualWidth)))
        .accessibilityAdjustableAction { direction in
            preferredWidth = clamp(actualWidth + (direction == .increment ? 20 : -20))
        }
    }

    private func clamp(_ width: Double) -> Double { min(range.upperBound, max(range.lowerBound, width)) }
}

/// Retain a narrow rail after collapsing so reopening is available in place.
/// It has no resize gesture: the hidden pane keeps its preferred width.
struct CollapsedPaneHandle: View {
    let expandsToRight: Bool
    let title: String
    let expand: () -> Void

    var body: some View {
        ZStack {
            PaneDividerSurface()
            PaneToggleButton(pointsLeft: !expandsToRight, title: title,
                             identifier: expandsToRight ? "sidebar.expand" : "inspector.expand",
                             action: expand)
        }
        .frame(width: PaneLayout.divider)
    }
}

private struct PaneDividerSurface: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
    }
}

private struct PaneToggleButton: View {
    let pointsLeft: Bool
    let title: String
    let identifier: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: pointsLeft ? "chevron.left" : "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(hovering ? Color.accentColor : Color.primary.opacity(0.65))
                .frame(width: PaneLayout.divider, height: 32)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct ResizeCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class CursorView: NSView {
        override func resetCursorRects() {
            let half = max(0, (bounds.height - 32) / 2)
            for y in [bounds.minY, bounds.maxY - half] where half > 0 {
                addCursorRect(NSRect(x: bounds.minX, y: y, width: bounds.width, height: half), cursor: .resizeLeftRight)
            }
            addCursorRect(NSRect(x: bounds.minX, y: bounds.minY + half,
                                 width: bounds.width, height: min(32, bounds.height)), cursor: .pointingHand)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
