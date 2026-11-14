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
    private var observers: [any NSObjectProtocol] = []

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        scrollView.wantsLayer = true
        // Stops read top-first. The scroll view's layer is already flipped for a flipped clip view,
        // so a mask that flips itself again lands upside down — measured: the header band then
        // dissolves the footer edge and the footer band does nothing.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.frame = scrollView.bounds
        scrollView.layer?.mask = gradient

        // Neither view posts unless told to. Bounds is a scroll; frame is the first layout — a
        // mask sized before it stays zero-sized, and a zero-sized mask is no mask at all.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        let watched: [(NSNotification.Name, NSView)] = [
            (NSView.boundsDidChangeNotification, scrollView.contentView),
            (NSView.frameDidChangeNotification, scrollView)
        ]
        observers = watched.map { name, view in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    // Isolated so teardown may read the main-actor token; a nonisolated deinit cannot touch it.
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Recomputes the mask for the current scroll offset. Call after the list reloads or resizes.
    func update() {
        guard let scrollView else { return }
        let height = scrollView.bounds.height
        let contentHeight = scrollView.documentView?.bounds.height ?? 0
        let offset = scrollView.contentView.bounds.origin.y
        let insets = scrollView.contentInsets
        // Measured from the bars' inner edges, not the panel's: a row under the footer is hidden
        // whether or not it also runs past the bottom of the window.
        let topDistance = max(0, offset + insets.top)
        let bottomDistance = max(0, contentHeight + insets.bottom - height - offset)
        let topBand = Theme.Dissolve.topBand
        let bottomBand = Theme.Dissolve.bottomBand

        // Without this every scroll tick animates the stops and the mask smears behind the list.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = scrollView.bounds
        // What fits between the bars never passes under one. Measured against the inset height,
        // not the full one: a list taller than the gap but shorter than the panel still runs
        // under the footer. Below the summed bands the stops would run out of order.
        if contentHeight <= height - insets.top - insets.bottom || height <= topBand + bottomBand {
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
