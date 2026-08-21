import AppKit

/// The palette window: a borderless, non-activating panel hosting `PanelSurface`. Every flag here
/// prevents a specific bug — see the comment on each. Show/hide lives in `WindowController`.
final class Panel: NSPanel {
    /// The backdrop; content goes into this, never into `contentView` directly.
    let surface = PanelSurface(
        frame: NSRect(
            x: 0, y: 0, width: Theme.Size.panelWidth, height: Theme.Size.panelHeight))

    init() {
        super.init(
            contentRect: NSRect(
                x: 0, y: 0, width: Theme.Size.panelWidth, height: Theme.Size.panelHeight),
            // `.nonactivatingPanel`: showing the panel must not deactivate the app we paste into.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        // `.canJoinAllSpaces`: otherwise summoning yanks you to the Space the panel was made on.
        // `.fullScreenAuxiliary`: otherwise the panel is invisible over a full-screen app.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The surface draws the only background there is; the window itself must not paint one.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // AppKit otherwise infers a utility-window fade on `orderFront` and fights our own.
        animationBehavior = .none
        // `NSPanel` defaults to true: any `close()` would deallocate the panel out from under us.
        isReleasedWhenClosed = false
        // Otherwise a drag-select inside the search field drags the whole window.
        isMovableByWindowBackground = false
        // We dismiss on resign-key ourselves; AppKit's own hide-on-deactivate would race it.
        hidesOnDeactivate = false

        surface.autoresizingMask = [.width, .height]
        contentView = surface
    }

    /// Borderless windows refuse key by default, so the search field would never see a keystroke.
    override var canBecomeKey: Bool { true }

    /// Main-window status would route the main menu and app-level state at a summoned palette.
    override var canBecomeMain: Bool { false }
}
