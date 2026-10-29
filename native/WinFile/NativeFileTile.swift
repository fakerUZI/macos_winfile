import AppKit
import SwiftUI

/// Fixed-layout display surface. SwiftUI keeps the existing gestures, drag
/// sources and shared menus, without measuring text/icon stacks while scrolling.
struct NativeFileTile: NSViewRepresentable {
    let item: FileItem
    let selected: Bool
    let badge: NSImage?
    var isCut: Bool = false
    func makeNSView(context: Context) -> NativeFileTileView { NativeFileTileView(frame: .zero) }
    func updateNSView(_ view: NativeFileTileView, context: Context) {
        view.configure(item: item, selected: selected, badge: badge, isCut: isCut)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeFileTileView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 104, height: IconGridMetrics.pitch - 10)
    }
    static func dismantleNSView(_ view: NativeFileTileView, coordinator: ()) { view.cancelImage() }
}

final class NativeFileTileView: NSView {
    private static let cutSymbol: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) else { return nil }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: .pi / 2)
            symbol.draw(in: NSRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }()
    private let icon = NSImageView()
    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var item: FileItem?
    private var selected = false
    private var hovering = false
    private var isCut = false
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

    func configure(item: FileItem, selected: Bool, badge: NSImage?, isCut: Bool = false) {
        let changed = self.item != item
        if self.isCut != isCut { needsLayout = true }
        self.item = item
        self.selected = selected
        self.isCut = isCut
        name.stringValue = item.name
        detail.stringValue = item.isContainer ? item.typeDescription : item.sizeText
        self.badge.image = isCut ? Self.cutSymbol : badge
        self.badge.contentTintColor = isCut ? .secondaryLabelColor : nil
        self.badge.isHidden = !isCut && badge == nil
        updateColors()
        guard changed else { return }
        hovering = false
        updateColors()
        cancelImage()
        if item.isContainer {
            icon.contentTintColor = nil
            icon.image = FileIconService.folderPlaceholder
        } else {
            icon.image = NSImage(systemSymbolName: item.category.symbol, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
        }
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
        let badgeSize: CGFloat = isCut ? 14 : 18
        badge.frame = NSRect(x: icon.frame.maxX - badgeSize + 3, y: icon.frame.maxY - badgeSize + 3,
                             width: badgeSize, height: badgeSize)
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
            badge.layer?.backgroundColor = isCut ? NSColor.clear.cgColor : NSColor.controlBackgroundColor.cgColor
            badge.layer?.borderColor = isCut ? NSColor.clear.cgColor : NSColor.controlBackgroundColor.cgColor
        }
    }
}
