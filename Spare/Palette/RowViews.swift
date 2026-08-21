import AppKit

/// A text entry: primary line in full ink, a secondary line under it. The selection fill is drawn
/// by the row itself — the table runs with `selectionHighlightStyle = .none`.
final class TextRowView: NSView {
    /// Right-click. The row asks its owner for a menu rather than building one itself.
    var onMenu: (() -> NSMenu?)?

    private let fill = NSView()
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private var isSelected = false
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        fill.wantsLayer = true
        fill.layer?.cornerRadius = Theme.Radius.row
        // `NSBezierPath(roundedRect:)` draws circular corners; the design is the squircle.
        fill.layer?.cornerCurve = .continuous
        addSubview(fill)

        primary.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        primary.textColor = Theme.Colors.textPrimary
        primary.lineBreakMode = .byTruncatingTail
        secondary.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        secondary.textColor = Theme.Colors.textSecondary
        secondary.lineBreakMode = .byTruncatingTail
        for label in [primary, secondary] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        let inset = Theme.Spacing.md + Theme.Spacing.lg
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            primary.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.trailingAnchor.constraint(equalTo: primary.trailingAnchor),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(item: ClipboardItem, selected: Bool) {
        primary.stringValue = RowText.headline(item)
        secondary.stringValue = RowText.detail(item)
        isSelected = selected
        repaint()
    }

    override func layout() {
        super.layout()
        fill.frame = bounds.insetBy(dx: Theme.Spacing.md, dy: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        repaint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        repaint()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?()
    }

    /// `cgColor` is resolved, not dynamic, so every token is re-read when the appearance flips.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        primary.textColor = Theme.Colors.textPrimary
        secondary.textColor = Theme.Colors.textSecondary
        repaint()
    }

    private func repaint() {
        fill.layer?.backgroundColor = RowText.fillColor(selected: isSelected, hovered: isHovered)
    }
}

/// An image entry: a 64-point thumbnail beside a caption. `NSTableView` recycles cells, so an
/// async decode that lands after reuse would paint the wrong picture into the wrong row.
final class ImageRowView: NSView {
    static let thumbnailSize: CGFloat = 64

    var onMenu: (() -> NSMenu?)?

    private let fill = NSView()
    private let thumbnail = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    /// The row's current item. A decode whose token no longer matches is dropped on arrival.
    private var token: UUID?
    private var isSelected = false
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        fill.wantsLayer = true
        fill.layer?.cornerRadius = Theme.Radius.row
        fill.layer?.cornerCurve = .continuous
        addSubview(fill)

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        // Rounded here rather than baked into the cache, which is shared with other sizes.
        thumbnail.layer?.cornerRadius = Theme.Radius.thumbnail
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        caption.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        caption.textColor = Theme.Colors.textSecondary
        caption.lineBreakMode = .byTruncatingTail
        for view in [thumbnail, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        let inset = Theme.Spacing.md + Theme.Spacing.lg
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbnailSize),
            thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
            caption.leadingAnchor.constraint(
                equalTo: thumbnail.trailingAnchor, constant: Theme.Spacing.lg),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(item: ClipboardItem, selected: Bool) {
        token = item.id
        isSelected = selected
        caption.stringValue = RowText.detail(item)
        // Clear first: a recycled cell otherwise shows the previous row's picture until the decode
        // lands, and shows it forever if this row has no image at all.
        thumbnail.image = nil
        repaint()
        guard let path = item.imagePath else { return }
        let url = URL(fileURLWithPath: path)
        let side = Self.thumbnailSize * 2
        // A warm cache hit paints on the same frame, so a scroll never flickers through empty rows.
        if let warm = ImageThumbnail.cached(url, maxPixel: side) {
            thumbnail.image = warm
            return
        }
        let id = item.id
        Task { @MainActor [weak self] in
            let image = await ImageThumbnail.loadAsync(url, maxPixel: side)
            guard let self, self.token == id else { return }
            self.thumbnail.image = image
        }
    }

    override func layout() {
        super.layout()
        fill.frame = bounds.insetBy(dx: Theme.Spacing.md, dy: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        repaint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        repaint()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        caption.textColor = Theme.Colors.textSecondary
        repaint()
    }

    private func repaint() {
        fill.layer?.backgroundColor = RowText.fillColor(selected: isSelected, hovered: isHovered)
    }
}

/// "Pinned" / "History". A row like any other to the table; `ListController` refuses to select it.
final class SectionHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.Colors.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let inset = Theme.Spacing.md + Theme.Spacing.lg
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(title: String) {
        label.stringValue = title.uppercased()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        label.textColor = Theme.Colors.textTertiary
    }
}

/// The strings and the one fill colour the three row views share.
private enum RowText {
    static func fillColor(selected: Bool, hovered: Bool) -> CGColor? {
        if selected { return Theme.Colors.selection.cgColor }
        return hovered ? Theme.Colors.rowHover.cgColor : nil
    }

    /// The first non-blank line, so a copy that starts with newlines still shows its content.
    static func headline(_ item: ClipboardItem) -> String {
        guard let text = item.text else { return "Image" }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Source app and size — the second line, and the whole caption on an image row.
    static func detail(_ item: ClipboardItem) -> String {
        var parts: [String] = []
        if let app = item.sourceApp?.split(separator: ".").last { parts.append(String(app)) }
        switch item.kind {
        case .image: parts.append("Image")
        case .text: parts.append(size(of: item.text ?? ""))
        }
        return parts.joined(separator: " · ")
    }

    /// `utf8.count` is O(1); `count` would walk graphemes across a multi-MB copy on every reload.
    private static func size(of text: String) -> String {
        let bytes = text.utf8.count
        guard bytes > ClipboardItem.searchKeyLimit else { return "\(text.count) characters" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
