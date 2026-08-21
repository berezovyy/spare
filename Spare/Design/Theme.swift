import AppKit

/// Central design tokens. Dark is the design and is frozen; light is the same stop with the ink
/// inverted. One alpha ramp, never grays.
enum Theme {
    enum Size {
        static let panelWidth: CGFloat = 750
        static let panelHeight: CGFloat = 475
        static let headerHeight: CGFloat = 44
        /// Room above the search row, constant so typing never shifts the bar.
        static let headerPadding: CGFloat = 10
        static let footerHeight: CGFloat = 52
        static let rowIcon: CGFloat = 24
        static let keyCap: CGFloat = 18
        static let listWidth: CGFloat = 290
    }

    enum Radius {
        static let panel: CGFloat = 26
        static let row: CGFloat = 10
        static let thumbnail: CGFloat = 6
        static let keyCap: CGFloat = 6
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
    }

    /// Band lengths and floor alphas of the scroll-driven edge mask; the bands are the bar heights
    /// plus Raycast's overshoot into the list (32 below the header, 28 above the footer).
    enum Dissolve {
        static let topBand: CGFloat = Size.headerHeight + Size.headerPadding + 32
        static let bottomBand: CGFloat = Size.footerHeight + 28
        static let topFloor: CGFloat = 0.15
        static let bottomFloor: CGFloat = 0.25
    }

    enum Typography {
        static let searchFieldSize: CGFloat = 20
        static let keyCapSize: CGFloat = 11

        static func searchField() -> NSFont {
            NSFont.systemFont(ofSize: searchFieldSize, weight: .regular)
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

        /// The ramp's inverse: the scrim darkens the dark surface and lightens the light one.
        static let panelScrim = adaptive(dark: ink(0, 0.40), light: ink(1, 0.55))
        /// Selection fill, shared by every list so they look identical.
        static let selection = ramp(dark: 0.10, light: 0.09)
        /// Mouse hover: a fainter layer, visually distinct from selection.
        static let rowHover = ramp(dark: 0.05, light: 0.045)
        static let separator = ramp(dark: 0.10, light: 0.12)
        /// Small control surfaces: keycap chips, glyph tiles.
        static let controlSurface = ramp(dark: 0.10, light: 0.08)
        /// Alpha 1, so a call site can dim it and land on the value it replaced.
        static let textPrimary = ramp(dark: 1.0, light: 1.0)
        static let textSecondary = ramp(dark: 0.60, light: 0.60)
        static let textTertiary = ramp(dark: 0.40, light: 0.42)
        /// White in both: frost brightens glass rather than inking it, and light glass needs more
        /// of it to read at all.
        static let glassFrost = adaptive(dark: ink(1, 0.05), light: ink(1, 0.25))
    }
}
