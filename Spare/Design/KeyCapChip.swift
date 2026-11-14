import AppKit

/// A keycap — "↵", "⌘3" — drawn as a layer-backed view. Deliberately not an `NSButton`: the
/// search field keeps first responder, and a chip must never take it away.
final class KeyCapChip: NSView {
    /// "↵" falls back to a face that seats high, so nudge that one glyph down when drawing.
    private static let returnGlyphDrop: CGFloat = 1

    private let label = NSTextField(labelWithString: "")
    private var labelCenter: NSLayoutConstraint?

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            labelCenter?.constant = newValue == "↵" ? Self.returnGlyphDrop : 0
        }
    }

    init(text: String = "") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.keyCap
        layer?.cornerCurve = .continuous

        label.font = Theme.Typography.keyCap()
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let center = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        labelCenter = center
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            center,
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 8),
            // Hug the glyph: with only minimums, a stack view hands the chip any spare width.
            {
                let snug = widthAnchor.constraint(equalTo: label.widthAnchor, constant: 8)
                snug.priority = .defaultHigh
                return snug
            }(),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.keyCap),
            heightAnchor.constraint(equalToConstant: Theme.Size.keyCap)
        ])
        self.text = text
        repaint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    /// `cgColor` is resolved, not dynamic: resolve under this view's own appearance.
    private func repaint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Colors.controlSurface.cgColor
        }
        label.textColor = Theme.Colors.textSecondary
    }
}
