import AppKit

/// A footer hint cap — "⌘", "↵" — drawn as a layer-backed view. Deliberately not an `NSButton`:
/// the search field keeps first responder, and a chip must never take it away.
final class KeyCapChip: NSView {
    /// "↵" falls back to a face that seats high, so nudge that one glyph down when drawing.
    private static let returnGlyphDrop: CGFloat = 1

    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.keyCap
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.Colors.controlSurface.cgColor

        label.font = Theme.Typography.keyCap()
        label.textColor = Theme.Colors.textSecondary
        label.alignment = .center
        label.stringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let drop = text == "↵" ? Self.returnGlyphDrop : 0
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: drop),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 8),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.keyCap),
            heightAnchor.constraint(equalToConstant: Theme.Size.keyCap)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `cgColor` is resolved, not dynamic, so repaint the fill when the appearance flips.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.Colors.controlSurface.cgColor
        label.textColor = Theme.Colors.textSecondary
    }
}
