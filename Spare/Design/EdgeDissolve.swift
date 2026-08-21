import AppKit

/// Scroll-driven mask so the list dissolves under the floating bars instead of clipping against
/// them. There are no separators between header, list and footer — this is what replaces them.
@MainActor
final class EdgeDissolve {
    /// Raycast's easing: full ink until content hides behind the bar, then down to the floor over
    /// one band's worth of scrolling. Pure, so `geometry-test` can call it without a window.
    static func alpha(distance: CGFloat, band: CGFloat, floor: CGFloat) -> CGFloat {
        guard band > 0 else { return 1 }
        let progress = min(max(distance / band, 0), 1)
        return 1 - (1 - floor) * progress
    }

    private weak var scrollView: NSScrollView?
    private let gradient = CAGradientLayer()
    private var observer: (any NSObjectProtocol)?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        scrollView.wantsLayer = true
        // Unit coordinates run bottom-up on a CALayer; flip once here so the stops read top-first.
        gradient.isGeometryFlipped = true
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.frame = scrollView.bounds
        scrollView.layer?.mask = gradient

        // The clip view posts this only when it is told to; a scroll otherwise moves in silence.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Recomputes the mask for the current scroll offset. Call after the list reloads or resizes.
    func update() {
        guard let scrollView else { return }
        let height = scrollView.bounds.height
        let contentHeight = scrollView.documentView?.bounds.height ?? 0
        let offset = scrollView.contentView.bounds.origin.y
        let topDistance = max(0, offset)
        let bottomDistance = max(0, contentHeight - height - offset)
        let topBand = Theme.Dissolve.topBand
        let bottomBand = Theme.Dissolve.bottomBand

        // Without this every scroll tick animates the stops and the mask smears behind the list.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = scrollView.bounds
        // Below the summed bands the stops would run out of order, so the mask stays fully opaque.
        if contentHeight <= height || height <= topBand + bottomBand {
            gradient.colors = [Self.ink(1), Self.ink(1)]
            gradient.locations = [0, 1]
        } else {
            let topAlpha = Self.alpha(
                distance: topDistance, band: topBand, floor: Theme.Dissolve.topFloor)
            let bottomAlpha = Self.alpha(
                distance: bottomDistance, band: bottomBand, floor: Theme.Dissolve.bottomFloor)
            gradient.colors = [
                Self.ink(0), Self.ink(topAlpha), Self.ink(1),
                Self.ink(1), Self.ink(bottomAlpha), Self.ink(0)
            ]
            gradient.locations = [
                0,
                NSNumber(value: Double(topBand / 2 / height)),
                NSNumber(value: Double(topBand / height)),
                NSNumber(value: Double(1 - bottomBand / height)),
                NSNumber(value: Double(1 - bottomBand / 2 / height)),
                1
            ]
        }
        CATransaction.commit()
    }

    /// A mask reads only the alpha channel, so the colour itself is irrelevant.
    private static func ink(_ alpha: CGFloat) -> CGColor {
        CGColor(gray: 0, alpha: alpha)
    }
}
