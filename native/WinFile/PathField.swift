// 原生路径输入框：支持 Tab 补全、↑↓ 选择、Enter 跳转、Esc 取消
// 用 NSTextField 实现，兼容 macOS 13 并符合 AppKit 输入习惯
import AppKit
import SwiftUI

struct PathField: NSViewRepresentable {
    @Binding var text: String
    var suggestions: [PathSuggestion]
    var onSubmit: (String) -> Void
    var onCancel: () -> Void
    var onTextChange: (String) -> Void
    var onAcceptSuggestion: (PathSuggestion, Bool) -> Void   // (候选, 是否需要继续深入)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = NSLocalizedString("path.placeholder", comment: "输入路径")
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

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        context.coordinator.suggestions = suggestions
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
