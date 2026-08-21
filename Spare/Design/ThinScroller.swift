import AppKit

/// A thin overlay scroller: an 8-point knob in the theme's ink, no track. Pair with the
/// `AppleShowScrollBars = WhenScrolling` default the app sets before any scroll view exists.
final class ThinScroller: NSScroller {
    private static let knobWidth: CGFloat = 4
    private static let knobInset: CGFloat = 2
    private static let knobMinimumLength: CGFloat = 24

    /// The slot the scroller occupies. Overlay scrollers float, so this is only the hit width.
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        8
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track: the list dissolves at its edges and a slot would draw a hard line through it.
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0, knob.width > 0 else { return }
        let height = max(knob.height, Self.knobMinimumLength)
        let shape = NSRect(
            x: knob.midX - Self.knobWidth / 2,
            y: max(0, min(knob.origin.y, bounds.maxY - height - Self.knobInset)),
            width: Self.knobWidth,
            height: height
        )
        Theme.Colors.textTertiary.setFill()
        NSBezierPath(roundedRect: shape, xRadius: Self.knobWidth / 2, yRadius: Self.knobWidth / 2)
            .fill()
    }
}
