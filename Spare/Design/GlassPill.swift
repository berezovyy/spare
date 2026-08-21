import AppKit

/// A floating capsule of glass. Glass belongs only on controls that float *inside* PanelSurface —
/// on a bare panel it falls back to an opaque backing and draws a dark edge.
final class GlassPill: NSView {
    private let backing: NSView

    init() {
        // Guard the class as well as the version: a runtime without it must fall back, not trap.
        if #available(macOS 26.0, *), NSClassFromString("NSGlassEffectView") != nil {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = Theme.Colors.glassFrost
            backing = glass
        } else {
            // Frosted blur plus the same tint, which is what the glass would have brightened to.
            let blur = NSVisualEffectView()
            blur.blendingMode = .withinWindow
            blur.material = .hudWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.backgroundColor = Theme.Colors.glassFrost.cgColor
            backing = blur
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        backing.autoresizingMask = [.width, .height]
        backing.frame = bounds
        addSubview(backing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        // Capsule: the radius is half the height, so it tracks whatever the pill is laid out to.
        let radius = bounds.height / 2
        layer?.cornerRadius = radius
        if #available(macOS 26.0, *), let glass = backing as? NSGlassEffectView {
            glass.cornerRadius = radius
        }
    }
}
