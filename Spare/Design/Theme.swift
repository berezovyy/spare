import AppKit

/// Central design tokens, tuned for Liquid Glass. Light and dark share one alpha ramp with the ink
/// inverted — never grays, so every fill reads through the glass under it.
enum Theme {
    enum Size {
        static let panelWidth: CGFloat = 560
        static let panelHeight: CGFloat = 360
        static let headerHeight: CGFloat = 44
        /// Room above the search row, constant so typing never shifts the bar.
        static let headerPadding: CGFloat = 4
        /// Air between the search row and the first list row.
        static let listTopGap: CGFloat = 4
        /// There is no footer; this is only the breathing room under the last row.
        static let listBottomInset: CGFloat = 8
        static let rowHeight: CGFloat = 36
        static let rowIcon: CGFloat = 20
        static let thumbnail: CGFloat = 24
        static let searchGlyph: CGFloat = 15
        static let keyCap: CGFloat = 18
        static let emptyGlyph: CGFloat = 26
        /// The ⌘-hold hint bar floating over the bottom of the list.
        static let hintBarHeight: CGFloat = 32
    }

    enum Radius {
        /// Near-concentric: the row fill sits `Spacing.sm` in, so row + inset ≈ panel.
        static let panel: CGFloat = 18
        static let row: CGFloat = 11
        static let thumbnail: CGFloat = 5
        static let keyCap: CGFloat = 5
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 16
    }

    /// One place for every duration and curve, so the panel, the list and the dialog move alike.
    enum Motion {
        /// Summon: a spring that settles without a visible overshoot, like a system popover.
        static let appearDuration: CFTimeInterval = 0.34
        static let appearBounce: CGFloat = 0.08
        static let appearScale: CGFloat = 0.96
        static let appearFade: TimeInterval = 0.12
        /// Dismiss is quicker than summon: the user has already moved on.
        static let dismissDuration: TimeInterval = 0.14
        static let dismissScale: CGFloat = 0.97
        /// The ⌘-hold hints: how long ⌘ must be held before they show, so a quick ⌘P never
        /// flashes them, and how fast they come and go.
        static let hintDelay: TimeInterval = 0.35
        static let hintFade: TimeInterval = 0.15
        /// How long "Deleted · ⌘Z Undo" stays up; ⌘Z keeps working until the panel closes.
        static let undoLinger: TimeInterval = 4
        /// The selection pill gliding between rows.
        static let selectionDuration: TimeInterval = 0.2
        /// Ease-out with a soft tail, the curve AppKit's own highlights settle on.
        /// Computed, not stored: `CAMediaTimingFunction` is not `Sendable`, so a static would not be.
        static var easeOut: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        }
        static var easeIn: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        }

        /// Reduce Motion keeps the fades and drops every scale and slide.
        @MainActor static var isReduced: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    /// Band lengths and floor alphas of the scroll-driven edge mask. The top band is the search
    /// row plus an overshoot into the list; the bottom has no bar, only the panel's edge. The
    /// floors are zero: on glass, a row ghosting through the search text reads as a bug.
    enum Dissolve {
        static let topBand: CGFloat = Size.headerHeight + Size.headerPadding + 24
        static let bottomBand: CGFloat = Size.listBottomInset + 24
        static let topFloor: CGFloat = 0
        static let bottomFloor: CGFloat = 0
    }

    enum Typography {
        static let searchFieldSize: CGFloat = 18
        static let keyCapSize: CGFloat = 11

        static func searchField() -> NSFont {
            NSFont.systemFont(ofSize: searchFieldSize, weight: .regular)
        }

        static func rowTitle() -> NSFont {
            NSFont.systemFont(ofSize: 13, weight: .regular)
        }

        /// The matched words in a row title: one step heavier, never a colour.
        static func rowMatch() -> NSFont {
            NSFont.systemFont(ofSize: 13, weight: .semibold)
        }

        static func rowDetail() -> NSFont {
            NSFont.systemFont(ofSize: 11, weight: .regular)
        }

        static func sectionTitle() -> NSFont {
            NSFont.systemFont(ofSize: 11, weight: .semibold)
        }

        static func keyCap() -> NSFont {
            NSFont.systemFont(ofSize: keyCapSize, weight: .regular)
        }
    }

    enum Colors {
        /// Resolves against the window's `effectiveAppearance`, so a token repaints on its own when
        /// the system flips between Light and Dark.
        private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }

        /// Built in sRGB, so a token's dark branch is the exact pixel the design shipped.
        private static func ink(_ white: CGFloat, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
        }

        /// The alpha ramp, inverted: white ink over the dark surface, black ink over the light one.
        private static func ramp(dark: CGFloat, light: CGFloat) -> NSColor {
            adaptive(dark: ink(1, dark), light: ink(0, light))
        }

        /// Pulls the glass toward the ink's opposite so text keeps its contrast over any wallpaper.
        static let glassTint = adaptive(dark: ink(0, 0.30), light: ink(1, 0.40))
        /// Selection fill: the one accent in the palette. Dynamic, so it follows the user's
        /// accent colour; resolve it under the view's appearance before taking a `cgColor`.
        static let selection = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.32 : 0.20)
        }
        /// Mouse hover: a fainter layer, visually distinct from selection.
        static let rowHover = ramp(dark: 0.05, light: 0.04)
        static let separator = ramp(dark: 0.10, light: 0.12)
        /// Small control surfaces: keycap chips, glyph tiles.
        static let controlSurface = ramp(dark: 0.10, light: 0.08)
        /// Alpha 1, so a call site can dim it and land on the value it replaced.
        static let textPrimary = ramp(dark: 1.0, light: 1.0)
        static let textSecondary = ramp(dark: 0.60, light: 0.60)
        static let textTertiary = ramp(dark: 0.40, light: 0.42)
    }
}
