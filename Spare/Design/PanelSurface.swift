import AppKit

/// The panel's backdrop: a scrim over behind-window blur, clipped to a continuous corner. There is
/// no solid background anywhere — depth comes from the desktop showing through.
final class PanelSurface: NSView {
    private let blur = NSVisualEffectView()
    private let scrim = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.panel
        // `NSBezierPath(roundedRect:)` would draw circular corners; the design is the squircle.
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)

        // Above the blur: the scrim darkens the dark surface and lightens the light one.
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = Theme.Colors.panelScrim.cgColor
        scrim.autoresizingMask = [.width, .height]
        scrim.frame = bounds
        addSubview(scrim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    /// `cgColor` is resolved, not dynamic, so the scrim is repainted when the appearance flips.
    override func updateLayer() {
        super.updateLayer()
        scrim.layer?.backgroundColor = Theme.Colors.panelScrim.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
