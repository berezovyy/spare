import AppKit

/// Owns the panel and everything inside it. Show and hide are the whole file: the order of the
/// calls below is load-bearing, and each line has a bug behind it.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    /// Return on a row, or a click. AppCore turns this into a paste.
    var onActivate: ((ClipboardItem) -> Void)?
    /// Right-click on a row; the owner builds the menu because it owns the actions.
    var onMenu: ((ClipboardItem) -> NSMenu?)?
    /// Set while our own confirm dialog is up: its key window makes the panel resign, and without
    /// this "Delete all history?" would dismiss the palette out from under itself.
    var isPresentingDialog = false

    /// The top margin is a fraction of the screen, not a constant: 200 pt reads as centred on a
    /// laptop and glued to the top edge of a 6K display.
    private static let topMarginFraction: CGFloat = 0.18
    private static let fadeDuration: TimeInterval = 0.09

    private let panel = Panel()
    private let searchField = SearchField(placeholder: "Search clipboard history")
    private let list: ListController
    private let footer = FooterBar()

    /// The app that was frontmost before we appeared, or our own key window when it was us.
    private var previousApp: NSRunningApplication?
    private var previousOwnWindow: NSWindow?
    /// Top-left, cached for the session: re-reading `visibleFrame` mid-session makes the panel
    /// jump the moment the Dock appears. Dropped on hide.
    private var anchor: NSPoint?
    /// True while `setFrame` is ours, so `windowDidMove` does not record it as a user drag.
    private var isMovingPanel = false
    private var dragMonitor: Any?

    init(store: ClipboardStore) {
        list = ListController(store: store)
        super.init()

        panel.delegate = self
        searchField.onQueryChange = { [weak self] in self?.list.queryChanged($0) }
        searchField.onMove = { [weak self] in self?.list.move($0) }
        searchField.onActivate = { [weak self] in self?.activateSelection() }
        searchField.onCancel = { [weak self] in self?.hide(restoreFocus: true) }
        // Backspace on an empty query clears the filter before it closes anything.
        searchField.onBackOut = { [weak self] in self?.clearFilter() ?? false }
        list.onActivate = { [weak self] in self?.onActivate?($0) }
        list.onMenu = { [weak self] in self?.onMenu?($0) }
        footer.onFilterChange = { [weak self] in self?.list.filterChanged($0) }

        layOutContent()
        installDragTracking()
    }

    // MARK: - Layout

    private func layOutContent() {
        let surface = panel.surface
        for view in [searchField, list.scrollView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        let margin = Theme.Spacing.lg + Theme.Spacing.md
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(
                equalTo: surface.topAnchor, constant: Theme.Size.headerPadding),
            searchField.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: margin),
            searchField.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor, constant: -margin),
            searchField.heightAnchor.constraint(equalToConstant: Theme.Size.headerHeight),
            // The list runs edge to edge under both bars; `contentInsets` keeps rows out from
            // under them, and the dissolve is what replaces the separators.
            list.scrollView.topAnchor.constraint(equalTo: surface.topAnchor),
            list.scrollView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            list.scrollView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            list.scrollView.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Theme.Size.footerHeight)
        ])
    }

    // MARK: - Show

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide(restoreFocus: true) } else { show() }
    }

    func show() {
        captureFocus()
        searchField.stringValue = ""
        list.reload()

        positionPanel()
        // Flush the first-mount layout while the panel is still off-screen.
        panel.contentView?.layoutSubtreeIfNeeded()
        // Set before ordering front: the other order shows one opaque frame.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // An inactive app cannot bring a window forward with `orderFront` alone.
        panel.orderFrontRegardless()
        panel.makeFirstResponder(searchField)
        fade(to: 1)

        // A login-item process that has never been activated can drop its first key request —
        // the panel is visible, looks focused, and eats no keys. A no-op the rest of the time.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        fade(to: 0) { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return }
            self.panel.orderOut(nil)
        }
        // Preview bitmaps are the memory; row thumbnails stay warm for the next summon.
        ImageThumbnail.purgePreviews()
        anchor = nil
        searchField.stringValue = ""
        if restoreFocus { restorePreviousFocus() }
        previousApp = nil
        previousOwnWindow = nil
    }

    private func activateSelection() {
        guard let item = list.selectedItem else { return }
        onActivate?(item)
    }

    private func clearFilter() -> Bool {
        footer.apply(.all)
        list.filterChanged(.all)
        return true
    }

    // MARK: - Focus

    /// Captured before ordering front — after it, the frontmost app is us.
    private func captureFocus() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier == NSRunningApplication.current.processIdentifier {
            previousApp = nil
            // Never the panel itself: a re-show while it holds key would target itself.
            if let key = NSApp.keyWindow, key !== panel { previousOwnWindow = key }
        } else {
            previousApp = frontmost
            previousOwnWindow = nil
        }
    }

    /// Our own window first: it is still open, and activating another app would bury it.
    private func restorePreviousFocus() {
        if let own = previousOwnWindow, own.isVisible {
            own.makeKeyAndOrderFront(nil)
        } else {
            previousApp?.activate()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, !isPresentingDialog else { return }
        // The user gave focus to something else themselves; yanking them back would be rude.
        hide(restoreFocus: false)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isMovingPanel else { return }
        anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    // MARK: - Placement

    /// `NSScreen.main` is the key window's screen — i.e. wherever the user last clicked in another
    /// app — so it is never the answer to "which display should this open on".
    private static func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        // `NSMouseInRect`, not `contains`: a screen's rows are half-open at the top, so the top
        // row of one display otherwise reads as the bottom row of the display above it.
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func positionPanel() {
        guard let screen = Self.screenUnderCursor() else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: Theme.Size.panelWidth, height: Theme.Size.panelHeight)
        let top =
            anchor
            ?? NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - visible.height * Self.topMarginFraction)
        anchor = top
        // AppKit frames are bottom-left, so a changing height would otherwise move the top edge.
        setFrame(NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height))
    }

    private func setFrame(_ frame: NSRect) {
        isMovingPanel = true
        panel.setFrame(frame, display: false)
        isMovingPanel = false
        // A window's shadow is computed from the frame at first draw and never again.
        panel.invalidateShadow()
    }

    /// Cancelling an in-flight fade needs an animation group; a plain assignment leaves the
    /// `CAAnimation` running and it snaps back.
    private func fade(to alpha: CGFloat, then finish: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.invalidateShadow()
                finish?()
            }
        }
    }

    // MARK: - Drag

    /// The header strip drags the window. `performDrag(with:)` hands the gesture to the window
    /// server and returns immediately — it can say a drag started, never that it ended.
    private func installDragTracking() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let strip = Theme.Size.headerHeight + Theme.Size.headerPadding
            guard event.locationInWindow.y > self.panel.frame.height - strip else { return event }
            self.trackDrag(from: event)
            return nil
        }
    }

    private func trackDrag(from event: NSEvent) {
        var last = NSEvent.mouseLocation
        var origin = panel.frame.origin
        panel.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking
        ) { tracked, stop in
            guard let tracked else {
                stop.pointee = true
                return
            }
            if tracked.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            // Deltas off `mouseLocation`: converting `locationInWindow` while the window moves
            // under the cursor compounds error every frame and the panel drifts away.
            let now = NSEvent.mouseLocation
            origin.x += now.x - last.x
            origin.y += now.y - last.y
            last = now
            self.setFrame(NSRect(origin: origin, size: self.panel.frame.size))
        }
        anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }
}
