import AppKit

/// A window's backdrop: one sheet of Liquid Glass, tinted toward the ink's opposite so text keeps
/// its contrast over any wallpaper. Content is added as siblings *above* the glass, never into
/// it — `NSGlassEffectView` only guarantees z-order for its own `contentView`.
final class PanelSurface: NSView {
    private let glass = NSGlassEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.panel
        // `NSBezierPath(roundedRect:)` would draw circular corners; the design is the squircle.
        layer?.cornerCurve = .continuous
        // Rows scroll under the corners; the clip keeps them inside the glass's own shape.
        layer?.masksToBounds = true

        glass.style = .regular
        glass.cornerRadius = Theme.Radius.panel
        applyTint()
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// Resolved to a concrete colour for the current appearance: re-assigning the same dynamic
    /// object on a Light/Dark flip may be ignored as unchanged, leaving the old branch's tint.
    private func applyTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glass.tintColor = Theme.Colors.glassTint.usingColorSpace(.sRGB)
        }
    }
}
