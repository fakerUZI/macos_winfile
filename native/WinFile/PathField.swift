// 原生路径输入框：支持 Tab 补全、↑↓ 选择、Enter 跳转、Esc 取消
// 用 NSTextField 实现，兼容 macOS 13 并符合 AppKit 输入习惯
import AppKit
import SwiftUI

/// Tracks the actual suggestion view so clicks on suggestions remain part of editing.
final class PathEditingRegions: ObservableObject {
    weak var suggestionView: NSView?
}

struct PathSuggestionRegion: NSViewRepresentable {
    let regions: PathEditingRegions
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { regions.suggestionView = view }
}

final class PathEditingTextField: NSTextField {
    weak var regions: PathEditingRegions?
    var onOutsideClick: (() -> Void)?
    private var mouseMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMouseMonitor()
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { return event }
            if let suggestionView = self.regions?.suggestionView, suggestionView.window === window,
               suggestionView.bounds.contains(suggestionView.convert(event.locationInWindow, from: nil)) { return event }
            DispatchQueue.main.async { [weak self] in self?.onOutsideClick?() }
            return event
        }
    }

    func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
    }

    deinit { removeMouseMonitor() }
}

struct PathField: NSViewRepresentable {
    @Binding var text: String
    let regions: PathEditingRegions
    var suggestions: [PathSuggestion]
    var onSubmit: (String) -> Void
    var onCancel: () -> Void
    var onTextChange: (String) -> Void
    var onAcceptSuggestion: (PathSuggestion, Bool) -> Void   // (候选, 是否需要继续深入)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PathEditingTextField {
        let field = PathEditingTextField(string: text)
        field.regions = regions
        field.onOutsideClick = { [weak coordinator = context.coordinator] in coordinator?.parent.onCancel() }
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = WLocalizedString("path.placeholder", comment: "输入路径")
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: PathEditingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        context.coordinator.suggestions = suggestions
    }

    static func dismantleNSView(_ field: PathEditingTextField, coordinator: Coordinator) {
        field.onOutsideClick = nil
        field.removeMouseMonitor()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PathField
        var suggestions: [PathSuggestion] = []

        init(_ parent: PathField) {
            self.parent = parent
            self.suggestions = parent.suggestions
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                if let first = suggestions.first {
                    parent.onAcceptSuggestion(first, true)
                }
                return true
            case #selector(NSResponder.moveDown(_:)):
                if let first = suggestions.first {
                    parent.onAcceptSuggestion(first, false)
                }
                return true
            default:
                return false
            }
        }
    }
}

/// 补全下拉列表（SwiftUI 绘制，浮在输入框下方）
struct PathSuggestionList: View {
    @ObservedObject private var localization = Localization.shared
    let suggestions: [PathSuggestion]
    let onPick: (PathSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions.prefix(10)) { suggestion in
                Button {
                    onPick(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.isDirectory ? "folder.fill" : "doc.text")
                            .foregroundStyle(suggestion.isDirectory ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(suggestion.name).fontWeight(.medium)
                            Text(suggestion.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .shadow(radius: 10, y: 3)
    }
}
