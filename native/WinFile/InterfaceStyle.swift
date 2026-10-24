import SwiftUI

/// Shared native surfaces use semantic colors so light, dark and increased
/// contrast appearances retain the same hierarchy.
enum InterfaceStyle {
    static let accent = Color.accentColor
    static let chrome = Color(nsColor: .windowBackgroundColor)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let softAccent = Color.primary.opacity(0.06)
    static let content = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
}

struct InsetSurface: ViewModifier {
    var radius: CGFloat = 8
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(InterfaceStyle.border.opacity(contrast == .increased ? 1 : 0.45)))
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
                    .background(InterfaceStyle.chrome, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: compact ? 20 : 27, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
                if !compact { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InterfaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(InterfaceStyle.border.opacity(0.6)))
        .help(detail)
        .accessibilityElement(children: .combine)
    }
}

/// An outlined destructive action stays distinct from the primary scan button.
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

/// Shared loading and empty states keep the next step visible without a modal alert.
struct InterfaceStateView: View {
    let symbol: String
    let title: String
    var detail = ""
    var loading = false

    var body: some View {
        VStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
                .frame(width: 40, height: 40).accessibilityHidden(true) }
            Text(title).font(.callout.weight(.medium))
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActiveFilterChip: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(.primary)
            .background(InterfaceStyle.softAccent, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(L("search.removeFilter", "移除条件：%@", title))
        .accessibilityLabel(L("search.removeFilter", "移除条件：%@", title))
    }
}


/// A common visual anchor for tool pages without adding another accent color.
struct PageIcon: View {
    let symbol: String
    var compact = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 20 : 24, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
            .accessibilityHidden(true)
    }
}

struct LeafToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonBody(configuration: configuration, enabled: enabled)
    }
    private struct ToolbarButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let enabled: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? (configuration.role == .destructive && (hovering || configuration.isPressed) ? Color.red : Color.primary) : Color.secondary.opacity(0.45))
                .frame(minWidth: 18, minHeight: 24)
                .background(enabled && (hovering || configuration.isPressed) ? InterfaceStyle.softAccent : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}
