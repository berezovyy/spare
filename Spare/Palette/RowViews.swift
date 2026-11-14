import AppKit

/// One entry, one line: what it came from, what it says. Everything else is earned — the source
/// and age show only on the selected row, the shortcut only while ⌘ is held. The selection fill
/// is not drawn here: `SelectionHighlight` glides between rows, so a row only stays out of its way.
final class ClipRowView: NSView {
    /// Right-click. The row asks its owner for a menu rather than building one itself.
    var onMenu: (() -> NSMenu?)?

    private let fill = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let meta = NSTextField(labelWithString: "")
    private let chip = KeyCapChip()
    private var iconSize: [NSLayoutConstraint] = []
    /// The row's current item. A thumbnail decode whose token no longer matches is dropped.
    private var token: UUID?
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

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerCurve = .continuous
        icon.layer?.masksToBounds = true
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pin.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        meta.font = Theme.Typography.rowDetail()
        meta.lineBreakMode = .byTruncatingHead

        let trailing = NSStackView(views: [pin, meta, chip])
        trailing.orientation = .horizontal
        trailing.spacing = Theme.Spacing.md
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, title, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        let side = Theme.Size.rowIcon
        iconSize = [icon.widthAnchor.constraint(equalToConstant: side),
                    icon.heightAnchor.constraint(equalToConstant: side)]
        NSLayoutConstraint.activate(iconSize + [
            // The icon's centre stays put whatever its size, so thumbnails and app icons share
            // a column with the search glyph above them.
            icon.centerXAnchor.constraint(
                equalTo: leadingAnchor, constant: RowMetrics.inset + Theme.Size.thumbnail / 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: RowMetrics.inset + Theme.Size.thumbnail + Theme.Spacing.lg),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(
                lessThanOrEqualTo: trailing.leadingAnchor, constant: -Theme.Spacing.lg),
            trailing.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -RowMetrics.inset),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        repaintInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `shortcut` is the 1-based number shown while ⌘ is held, nil otherwise.
    func configure(item: ClipboardItem, query: String, selected: Bool, shortcut: Int?) {
        token = item.id
        isSelected = selected
        title.attributedStringValue = RowText.title(item, emphasising: query)
        pin.isHidden = !item.isPinned
        meta.stringValue = RowText.meta(item, now: Date())
        meta.isHidden = !selected || shortcut != nil
        if let shortcut {
            chip.text = "⌘\(shortcut)"
            chip.isHidden = false
        } else {
            chip.text = "↵"
            chip.isHidden = !selected
        }
        configureIcon(item)
        repaintFill()
    }

    private func configureIcon(_ item: ClipboardItem) {
        let isImage = item.kind == .image
        let side = isImage ? Theme.Size.thumbnail : Theme.Size.rowIcon
        for constraint in iconSize { constraint.constant = side }
        icon.layer?.cornerRadius = isImage ? Theme.Radius.thumbnail : 0
        icon.contentTintColor = Theme.Colors.textTertiary
        guard isImage, let path = item.imagePath else {
            icon.image = AppIdentity.entry(for: item.sourceApp)?.icon ?? RowText.glyph(for: item)
            return
        }
        // Clear first: a recycled cell otherwise shows the previous row's picture until the
        // decode lands.
        icon.image = nil
        let url = URL(fileURLWithPath: path)
        let pixels = Theme.Size.thumbnail * 2
        // A warm cache hit paints on the same frame, so a scroll never flickers through gaps.
        if let warm = ImageThumbnail.cached(url, maxPixel: pixels) {
            icon.image = warm
            return
        }
        let id = item.id
        Task { @MainActor [weak self] in
            let image = await ImageThumbnail.loadAsync(url, maxPixel: pixels)
            guard let self, self.token == id else { return }
            self.icon.image = image
        }
    }

    override func layout() {
        super.layout()
        fill.frame = RowMetrics.fillFrame(in: bounds)
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
        repaintFill()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        repaintFill()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaintInk()
        repaintFill()
    }

    private func repaintInk() {
        title.textColor = Theme.Colors.textPrimary
        meta.textColor = Theme.Colors.textTertiary
        pin.contentTintColor = Theme.Colors.textTertiary
    }

    /// Hover only: under the highlight a second fill would double its ink.
    private func repaintFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.layer?.backgroundColor =
                isHovered && !isSelected ? Theme.Colors.rowHover.cgColor : nil
        }
    }
}

/// The one selection fill. It lives in the table below the row views and slides to the selected
/// row, which is what makes arrowing through the list read as motion rather than a blink.
final class SelectionHighlight: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.row
        layer?.cornerCurve = .continuous
        isHidden = true
        repaint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Clicks belong to the row underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        repaint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    /// The accent is dynamic twice over — appearance and the user's accent choice — so it is
    /// resolved here, under this view's appearance, rather than wherever `cgColor` runs.
    private func repaint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Colors.selection.cgColor
        }
    }

    /// Glides when it is already showing; appears in place when it was not, so the first frame
    /// never sweeps in from wherever the last session left it.
    func move(to frame: NSRect, animated: Bool) {
        let glide = animated && !isHidden && !Theme.Motion.isReduced
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            // A zero-length group still replaces an in-flight glide; a plain assignment would let
            // the old `CAAnimation` run on and snap back over the new frame.
            context.duration = glide ? Theme.Motion.selectionDuration : 0
            context.timingFunction = Theme.Motion.easeOut
            animator().frame = frame
        }
    }
}

/// Stands in for the list when there is nothing to show, and says why in plain words.
final class EmptyStateView: NSView {
    private let glyph = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.symbolConfiguration = .init(pointSize: Theme.Size.emptyGlyph, weight: .light)
        headline.font = .systemFont(ofSize: 13, weight: .medium)
        headline.lineBreakMode = .byTruncatingMiddle
        detail.font = Theme.Typography.rowDetail()
        for label in [headline, detail] { label.alignment = .center }
        let stack = NSStackView(views: [glyph, headline, detail])
        stack.orientation = .vertical
        stack.spacing = Theme.Spacing.sm
        stack.setCustomSpacing(Theme.Spacing.md, after: glyph)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        ])
        repaintInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(symbol: String, headline: String, detail: String) {
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.headline.stringValue = headline
        self.detail.stringValue = detail
        self.detail.isHidden = detail.isEmpty
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaintInk()
    }

    private func repaintInk() {
        glyph.contentTintColor = Theme.Colors.textTertiary
        headline.textColor = Theme.Colors.textSecondary
        detail.textColor = Theme.Colors.textTertiary
    }
}

/// Where row content and fills sit, shared so the highlight lands exactly on a row's own fill.
enum RowMetrics {
    /// Fill inset from the panel edge; content sits a further `Spacing.lg` inside the fill.
    static let fillInset = Theme.Spacing.sm
    static let inset = Theme.Spacing.sm + Theme.Spacing.lg

    static func fillFrame(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: fillInset, dy: 1)
    }
}

/// The strings the row shares with the empty state.
enum RowText {
    /// The first non-blank line; a link without its scheme, which is noise to a reader.
    static func headline(_ item: ClipboardItem) -> String {
        guard let text = item.text else { return "Image" }
        let line = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard item.textForm == .link else { return line }
        for scheme in ["https://", "http://"] where line.lowercased().hasPrefix(scheme) {
            return String(line.dropFirst(scheme.count))
        }
        return line
    }

    /// The headline with every query word set one weight heavier, so a glance says why a row
    /// is here. Case- and accent-blind, like the search itself.
    static func title(_ item: ClipboardItem, emphasising query: String) -> NSAttributedString {
        let text = headline(item)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: Theme.Typography.rowTitle(),
                .foregroundColor: Theme.Colors.textPrimary,
                .paragraphStyle: paragraph
            ])
        let source = text as NSString
        for word in query.split(whereSeparator: \.isWhitespace) {
            var range = NSRange(location: 0, length: source.length)
            while true {
                let hit = source.range(
                    of: String(word), options: [.caseInsensitive, .diacriticInsensitive],
                    range: range)
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                result.addAttribute(.font, value: Theme.Typography.rowMatch(), range: hit)
                let next = hit.location + hit.length
                range = NSRange(location: next, length: source.length - next)
            }
        }
        return result
    }

    /// Source app and age — shown only on the selected row.
    @MainActor static func meta(_ item: ClipboardItem, now: Date) -> String {
        let age = age(of: item.createdAt, now: now)
        guard let app = AppIdentity.entry(for: item.sourceApp)?.name else { return age }
        return "\(app) · \(age)"
    }

    /// Stands in for an app icon when the source app is unknown.
    static func glyph(for item: ClipboardItem) -> NSImage? {
        let name: String
        switch item.textForm {
        case .link: name = "link"
        case .email: name = "at"
        default: name = "doc.plaintext"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// "now", "4m", "3h", "2d", then a date. Short enough to sit beside the content.
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
