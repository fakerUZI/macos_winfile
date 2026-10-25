import AppKit
import SwiftUI

/// Fixed-layout display surface. SwiftUI keeps the existing gestures, drag
/// sources and shared menus, without measuring text/icon stacks while scrolling.
struct NativeFileTile: NSViewRepresentable {
    let item: FileItem
    let selected: Bool
    let badge: NSImage?
    func makeNSView(context: Context) -> NativeFileTileView { NativeFileTileView(frame: .zero) }
    func updateNSView(_ view: NativeFileTileView, context: Context) {
        view.configure(item: item, selected: selected, badge: badge)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeFileTileView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 104, height: IconGridMetrics.pitch - 10)
    }
    static func dismantleNSView(_ view: NativeFileTileView, coordinator: ()) { view.cancelImage() }
}

final class NativeFileTileView: NSView {
    private let icon = NSImageView()
    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var item: FileItem?
    private var selected = false
    private var hovering = false
    private var imageTask: Task<Void, Never>?

    override var isFlipped: Bool { true }
    // Gestures, context menus and drags belong to the surrounding SwiftUI tile.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.borderWidth = 0.75
        name.font = .systemFont(ofSize: 11)
        name.maximumNumberOfLines = 2
        name.cell?.wraps = true
        name.cell?.usesSingleLineMode = false
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for label in [name, detail] {
            label.alignment = .center
            label.isSelectable = false
        }
        for child in [icon, badge, name, detail] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { imageTask?.cancel() }
    func cancelImage() { imageTask?.cancel(); imageTask = nil }

    func configure(item: FileItem, selected: Bool, badge: NSImage?) {
        let changed = self.item != item
        self.item = item
        self.selected = selected
        name.stringValue = item.name
        detail.stringValue = item.isContainer ? item.typeDescription : item.sizeText
        self.badge.image = badge
        self.badge.isHidden = badge == nil
        updateColors()
        guard changed else { return }
        hovering = false
        updateColors()
        cancelImage()
        icon.image = NSImage(systemSymbolName: item.isContainer ? "folder.fill" : item.category.symbol,
                             accessibilityDescription: nil)
        icon.contentTintColor = item.isContainer ? item.category.tint : .secondaryLabelColor
        guard !AndroidURL.isAndroid(item.url) else { return }
        imageTask = Task { @MainActor [weak self] in
            let version = "\(item.modified?.timeIntervalSince1970 ?? 0)|\(item.size ?? 0)"
            var image: NSImage?
            if item.supportsThumbnail {
                image = await ThumbnailService.shared.thumbnail(for: item.url, size: 44, version: version).image
            }
            guard !Task.isCancelled else { return }
            if image == nil {
                image = await FileIconService.shared.thumbnail(for: item.url, size: 44, version: version).image
            }
            guard !Task.isCancelled, let self, self.item == item else { return }
            if let image { self.icon.contentTintColor = nil; self.icon.image = image }
        }
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 44) / 2, y: 6, width: 44, height: 44)
        badge.frame = NSRect(x: icon.frame.maxX - 18 + 3.24, y: 6 + 44 - 18 + 3.24, width: 18, height: 18)
        name.frame = NSRect(x: 8, y: 54, width: max(0, bounds.width - 16), height: FileItem.tileNameAreaHeight)
        detail.frame = NSRect(x: 8, y: 88, width: max(0, bounds.width - 16), height: 12)
    }
    // The grid owns hover tracking: recycled/moving tiles do not reliably receive
    // matching mouseExited events when the pointer stays still during scrolling.
    func setHovering(_ hovering: Bool) {
        guard self.hovering != hovering else { return }
        self.hovering = hovering
        updateColors()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                : hovering ? NSColor.separatorColor.withAlphaComponent(0.12) : .clear).cgColor
            layer?.borderWidth = selected ? 1 : 0
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
            badge.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            badge.layer?.borderColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}
