import SwiftUI

/// Shared native surfaces use semantic colors so light, dark and increased
/// contrast appearances retain the same hierarchy.
enum InterfaceStyle {
    static let chrome = Color(nsColor: .windowBackgroundColor)
    static let content = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
}

struct InsetSurface: ViewModifier {
    var radius: CGFloat = 8
    func body(content: Content) -> some View {
        content
            .background(InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(InterfaceStyle.border.opacity(0.6)))
    }
}

struct CleanupMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            if !compact {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(InterfaceStyle.chrome, in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: compact ? 20 : 27, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if !compact { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(InsetSurface())
        .help(detail)
        .accessibilityElement(children: .combine)
    }
}

/// An outlined destructive action stays distinct from the blue scan button.
struct TrashActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.red : Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(enabled && configuration.isPressed ? Color.red.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(enabled ? Color.red.opacity(0.65) : InterfaceStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
