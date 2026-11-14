import AppKit

/// Owns the panel and everything inside it. Show and hide are the whole file: the order of the
/// calls below is load-bearing, and each line has a bug behind it.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    /// Return on a row, a click, or ⌘1…⌘9. AppCore turns this into a paste.
    var onActivate: ((ClipboardItem) -> Void)?
    /// ⌘C: put the entry on the clipboard without pasting it anywhere.
    var onCopy: ((ClipboardItem) -> Void)?
    /// Set while our own confirm dialog is up: its key window makes the panel resign, and without
    /// this "Delete all history?" would dismiss the palette out from under itself.
    var isPresentingDialog = false

    /// The top margin is a fraction of the screen, not a constant: 200 pt reads as centred on a
    /// laptop and glued to the top edge of a 6K display.
    private static let topMarginFraction: CGFloat = 0.18

    private let panel = Panel()
    private let store: ClipboardStore
    private let searchField = SearchField(placeholder: "Search")
    private let searchGlyph = NSImageView()
    /// Says which filter is on, and clears it when clicked. Hidden while everything is shown.
    private let filterTag = NSButton(title: "", target: nil, action: nil)
    private let hintBar = HintBar()
    private let undoToast = UndoToast()
    /// Deleted while this summon is open, newest last: ⌘Z brings them back one at a time. Their
    /// image files are kept until the panel closes, so an undo is whole.
    private var undoable: [ClipboardItem] = []
    private var toastDismiss: DispatchWorkItem?
    private var toastShown = false
    private var fieldToEdge: NSLayoutConstraint?
    private var fieldToTag: NSLayoutConstraint?
    private let list: ListController

    /// The app that was frontmost before we appeared, or our own key window when it was us.
    private var previousApp: NSRunningApplication?
    private var previousOwnWindow: NSWindow?
    /// Top-left, cached for the session: re-reading `visibleFrame` mid-session makes the panel
    /// jump the moment the Dock appears. Dropped on hide.
    private var anchor: NSPoint?
    /// True while `setFrame` is ours, so `windowDidMove` does not record it as a user drag.
    private var isMovingPanel = false
    private var dragMonitor: Any?
    private var modifierMonitor: Any?
    /// The pending ⌘-hold reveal; cancelled by a release or by any ⌘-chord, so a quick ⌘P never
    /// flashes the hints.
    private var hintReveal: DispatchWorkItem?
    /// True from the start of a dismiss until the next summon. Escape restores focus, which
    /// resigns key mid-fade, and that second `hide` would restart the shrink from full size.
    private var isHiding = false

    init(store: ClipboardStore) {
        self.store = store
        list = ListController(store: store)
        super.init()

        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
        searchField.onQueryChange = { [weak self] in self?.list.queryChanged($0) }
        searchField.onMove = { [weak self] in self?.list.move($0) }
        searchField.onActivate = { [weak self] in self?.activateSelection() }
        searchField.onCancel = { [weak self] in self?.cancel() }
        // Backspace on an empty query clears the filter before it closes anything.
        searchField.onBackOut = { [weak self] in self?.clearFilter() ?? false }
        list.onActivate = { [weak self] in self?.onActivate?($0) }
        list.onMenu = { [weak self] in self?.menu(for: $0) }
        // A pin, a delete or a capture landing while the palette is open: re-render in place.
        store.onChange = { [weak self] in
            guard let self, self.panel.isVisible, !self.isHiding else { return }
            self.list.reload(keeping: self.list.selectedItem?.id)
            self.hintBar.update(selectionIsPinned: self.list.selectedItem?.isPinned == true)
        }

        layOutContent()
        installDragTracking()
        installModifierTracking()
    }

    isolated deinit {
        for monitor in [dragMonitor, modifierMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Layout

    private func layOutContent() {
        let surface = panel.surface
        searchGlyph.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchGlyph.symbolConfiguration = .init(
            pointSize: Theme.Size.searchGlyph, weight: .medium)
        searchGlyph.contentTintColor = Theme.Colors.textTertiary

        filterTag.bezelStyle = .glass
        filterTag.controlSize = .small
        filterTag.imagePosition = .imageTrailing
        filterTag.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Clear")
        filterTag.refusesFirstResponder = true
        filterTag.target = self
        filterTag.action = #selector(clearFilterClicked)
        filterTag.isHidden = true

        for view in [
            list.scrollView, list.emptyView, searchGlyph, searchField, filterTag, hintBar, undoToast,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        let margin = RowMetrics.inset
        let headerBottom = Theme.Size.headerPadding + Theme.Size.headerHeight
        let headerCenter = Theme.Size.headerPadding + Theme.Size.headerHeight / 2
        NSLayoutConstraint.activate([
            // The glyph shares the rows' icon column, so the header and the list line up.
            searchGlyph.centerXAnchor.constraint(
                equalTo: surface.leadingAnchor, constant: margin + Theme.Size.thumbnail / 2),
            searchGlyph.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            // Centred in the header, not stretched to it: a text field draws its line at the top
            // of its frame, so a tall field leaves the text riding above the glyph.
            searchField.centerYAnchor.constraint(
                equalTo: surface.topAnchor, constant: headerCenter),
            searchField.leadingAnchor.constraint(
                equalTo: surface.leadingAnchor,
                constant: margin + Theme.Size.thumbnail + Theme.Spacing.lg),
            filterTag.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor, constant: -(margin - Theme.Spacing.xs)),
            filterTag.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            list.emptyView.topAnchor.constraint(equalTo: surface.topAnchor, constant: headerBottom),
            list.emptyView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            list.emptyView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            list.emptyView.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            // The list runs edge to edge under the search row; `contentInsets` keeps rows out
            // from under it, and the dissolve is what replaces a separator.
            list.scrollView.topAnchor.constraint(equalTo: surface.topAnchor),
            list.scrollView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            list.scrollView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            list.scrollView.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            hintBar.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            hintBar.bottomAnchor.constraint(
                equalTo: surface.bottomAnchor, constant: -Theme.Spacing.lg),
            undoToast.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            undoToast.bottomAnchor.constraint(equalTo: hintBar.bottomAnchor),
        ])
        // Hidden views keep their constraints, so the field is tied to the tag only while the
        // tag shows; otherwise it runs to the panel's edge.
        fieldToEdge = searchField.trailingAnchor.constraint(
            equalTo: surface.trailingAnchor, constant: -margin)
        fieldToTag = searchField.trailingAnchor.constraint(
            equalTo: filterTag.leadingAnchor, constant: -Theme.Spacing.md)
        fieldToEdge?.isActive = true
        filterTag.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Keys

    /// Every ⌘-chord the palette answers. Plain keys never come here: they belong to the field,
    /// which routes arrows, Return and Escape itself.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // Only the chord keys: Caps Lock, Fn and the numeric-pad bit ride along on real events.
        let flags = event.modifierFlags.intersection(Self.chordModifiers)
        guard flags == .command else { return false }
        // Mid-dismiss the panel is still key; a second chord would paste twice.
        guard !isHiding else { return true }
        let key = ChordKey.resolve(
            withCommand: event.characters, typed: event.charactersIgnoringModifiers,
            keyCode: event.keyCode)
        cancelHints()
        if let number = Int(key), let item = list.item(number: number) {
            onActivate?(item)
            return true
        }
        switch (key, event.keyCode) {
        case ("p", _):
            if let item = list.selectedItem { store.togglePinned(item) }
        case (_, 51):  // ⌘⌫
            // With a query typed, ⌘⌫ is the editor's "delete to start of line", never a delete
            // of history the user did not mean.
            guard searchField.stringValue.isEmpty else { return false }
            if let item = list.selectedItem { delete(item) }
        case ("z", _):
            guard !undoable.isEmpty else { return false }
            undoDelete()
        case ("c", _):
            // A selection inside the query is the user copying their own words.
            if let editor = searchField.currentEditor(), editor.selectedRange.length > 0 {
                editor.copy(nil)
            } else if let item = list.selectedItem {
                onCopy?(item)
            }
        case ("f", _):
            showFilterMenu()
        // The app has no Edit menu, so the field's own chords are answered here.
        case ("v", _):
            searchField.currentEditor()?.paste(nil)
        case ("a", _):
            searchField.currentEditor()?.selectAll(nil)
        case ("x", _):
            searchField.currentEditor()?.cut(nil)
        default:
            return false
        }
        return true
    }

    /// Escape clears a query first, then a filter, then closes — one step back at a time.
    private func cancel() {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            list.queryChanged("")
        } else if list.filter != .all {
            _ = clearFilter()
        } else {
            hide(restoreFocus: true)
        }
    }

    /// Holding ⌘ alone, briefly, reveals the shortcuts; anything else hides them again.
    private func installModifierTracking() {
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection(Self.chordModifiers)
            if flags == .command {
                self.scheduleHints()
            } else {
                self.cancelHints()
            }
            return event
        }
    }

    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private func scheduleHints() {
        hintReveal?.cancel()
        let reveal = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setHintsVisible(true) }
        }
        hintReveal = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.hintDelay, execute: reveal)
    }

    private func cancelHints() {
        hintReveal?.cancel()
        hintReveal = nil
        setHintsVisible(false)
    }

    private func setHintsVisible(_ visible: Bool) {
        // A reveal scheduled during the dismiss fade must not light up a hidden panel.
        if visible, !panel.isVisible || isHiding || !panel.isKeyWindow { return }
        guard list.showsShortcuts != visible else { return }
        // One capsule at a time in the same spot; the hints say ⌘⌫ anyway.
        if visible { setToastVisible(false) }
        hintBar.update(selectionIsPinned: list.selectedItem?.isPinned == true)
        hintBar.setVisible(visible)
        list.showsShortcuts = visible
    }

    // MARK: - Delete and undo

    private func delete(_ item: ClipboardItem) {
        guard store.remove(item, keepingBlob: true) else { return }
        undoable.append(item)
        setToastVisible(true)
    }

    private func undoDelete() {
        guard let item = undoable.popLast() else { return }
        guard let restored = store.restore(item) else {
            // Still deleted: keep it owed to `settleDeletes`, so its file does not leak.
            undoable.append(item)
            return
        }
        // A query or filter typed since might hide it; an undo nobody can see reads as broken.
        if !list.rows.contains(where: { $0.id == restored.id }) {
            searchField.stringValue = ""
            list.queryChanged("")
            _ = clearFilter()
        }
        // The store re-rendered keeping the old selection; the restored row is what was meant.
        list.select(restored.id)
        setToastVisible(!undoable.isEmpty)
    }

    private func setToastVisible(_ visible: Bool) {
        toastDismiss?.cancel()
        toastDismiss = nil
        if visible {
            let dismiss = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.setToastVisible(false) }
            }
            toastDismiss = dismiss
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Theme.Motion.undoLinger, execute: dismiss)
        }
        // Tracked here, not read off the view: mid fade-out the toast is still unhidden.
        guard toastShown != visible else { return }
        toastShown = visible
        undoToast.setVisible(visible)
    }

    /// The undo window closes with the panel: whatever is still deleted goes for good.
    private func settleDeletes() {
        for item in undoable { store.discardBlob(of: item) }
        undoable.removeAll()
        setToastVisible(false)
    }

    // MARK: - Menus

    /// ⌘F. `NSMenu.popUp` runs its own event-tracking mode and owns the keyboard while it is
    /// up; a custom popover is what froze input in Tinycast.
    private func showFilterMenu() {
        let menu = NSMenu()
        for option in ClipboardFilter.allCases {
            let item = NSMenuItem(
                title: option.title, action: #selector(pickFilter), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = option == list.filter ? .on : .off
            item.image = NSImage(
                systemSymbolName: option.systemImage, accessibilityDescription: option.title)
            menu.addItem(item)
        }
        // Under the search glyph, where the eye already is. The surface is not flipped, so the
        // header's bottom edge is measured from the top.
        let surface = panel.surface
        let origin = NSPoint(
            x: RowMetrics.inset - Theme.Spacing.xs,
            y: surface.bounds.height - Theme.Size.headerPadding - Theme.Size.headerHeight)
        menu.popUp(positioning: nil, at: origin, in: surface)
    }

    @objc private func pickFilter(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? ClipboardFilter else { return }
        applyFilter(option)
    }

    @objc private func clearFilterClicked() {
        _ = clearFilter()
    }

    private func applyFilter(_ filter: ClipboardFilter) {
        filterTag.title = filter.shortTitle
        showFilterTag(filter != .all)
        list.filterChanged(filter)
    }

    private func showFilterTag(_ shown: Bool) {
        filterTag.isHidden = !shown
        // Deactivate before activating, or both hold for a moment and conflict.
        (shown ? fieldToEdge : fieldToTag)?.isActive = false
        (shown ? fieldToTag : fieldToEdge)?.isActive = true
    }

    /// The right-click menu: every action the selection has, so a mouse user needs no keys.
    private func menu(for item: ClipboardItem) -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, String, (WindowController) -> Void)] = [
            ("Paste", "arrow.turn.down.left", { $0.onActivate?(item) }),
            ("Copy", "doc.on.doc", { $0.onCopy?(item) }),
            (item.isPinned ? "Unpin" : "Pin", item.isPinned ? "pin.slash" : "pin",
             { $0.store.togglePinned(item) }),
            ("Delete", "trash", { $0.delete(item) })
        ]
        for (title, symbol, action) in entries {
            let entry = ClosureMenuItem(title: title) { [weak self] in
                guard let self else { return }
                action(self)
            }
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: - Show

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide(restoreFocus: true) } else { show() }
    }

    func show() {
        isHiding = false
        captureFocus()
        searchField.stringValue = ""
        // Every summon starts from everything: a filter left over from last time is the kind
        // of hidden state that makes a list look empty for no visible reason.
        showFilterTag(false)
        cancelHints()
        list.reset()

        positionPanel()
        // Size the list before filling it: on a cold first summon a reload into a zero-sized
        // table scrolls under the header and lays the highlight out zero-wide. Then flush the
        // rows' own layout, still off-screen.
        panel.contentView?.layoutSubtreeIfNeeded()
        list.reload()
        panel.contentView?.layoutSubtreeIfNeeded()
        // Set before ordering front: the other order shows one opaque frame.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // An inactive app cannot bring a window forward with `orderFront` alone.
        panel.orderFrontRegardless()
        panel.makeFirstResponder(searchField)
        fade(to: 1, duration: Theme.Motion.appearFade, timing: Theme.Motion.easeOut)
        animateScale(appearing: true)

        // A login-item process that has never been activated can drop its first key request —
        // the panel is visible, looks focused, and eats no keys. A no-op the rest of the time.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide(restoreFocus: Bool) {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        cancelHints()
        settleDeletes()
        animateScale(appearing: false)
        fade(to: 0, duration: Theme.Motion.dismissDuration, timing: Theme.Motion.easeIn) {
            [weak self] in
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
        guard list.filter != .all else { return false }
        applyFilter(.all)
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
    private func fade(
        to alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction,
        then finish: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.invalidateShadow()
                finish?()
            }
        }
    }

    /// The surface grows in on a spring and settles back on the way out, around its own centre.
    /// Only a presentation animation: the layer's model transform stays identity throughout, so
    /// hit-testing, layout and the window shadow never see a scaled panel.
    private func animateScale(appearing: Bool) {
        guard let layer = panel.surface.layer else { return }
        layer.removeAnimation(forKey: Self.scaleKey)
        guard !Theme.Motion.isReduced else { return }
        let animation: CABasicAnimation
        if appearing {
            let spring = CASpringAnimation(
                perceptualDuration: Theme.Motion.appearDuration, bounce: Theme.Motion.appearBounce)
            spring.duration = spring.settlingDuration
            spring.fromValue = Self.scale(Theme.Motion.appearScale, of: layer)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation = spring
        } else {
            animation = CABasicAnimation()
            animation.duration = Theme.Motion.dismissDuration
            animation.timingFunction = Theme.Motion.easeIn
            animation.toValue = Self.scale(Theme.Motion.dismissScale, of: layer)
            // Holds the shrunk frame until the fade has ordered the panel out; the next summon
            // removes it before it starts.
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        animation.keyPath = "transform"
        // The fade finishes before the spring settles; re-read the shadow once the panel is at
        // its final size, so it is never left traced from a scaled frame.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
        layer.add(animation, forKey: Self.scaleKey)
        CATransaction.commit()
    }

    private static let scaleKey = "spare.scale"

    /// A scale about the layer's centre. A view's layer is anchored at its bottom-left corner, so
    /// a bare scale would shrink the panel toward that corner instead.
    private static func scale(_ factor: CGFloat, of layer: CALayer) -> NSValue {
        let x = layer.bounds.width * (0.5 - layer.anchorPoint.x)
        let y = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        transform = CATransform3DTranslate(transform, -x, -y, 0)
        return NSValue(caTransform3D: transform)
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
            // The filter tag lives in the strip; its clicks are its own.
            let tag = self.filterTag
            if !tag.isHidden,
                tag.bounds.contains(tag.convert(event.locationInWindow, from: nil))
            {
                return event
            }
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

/// A menu item that runs a closure, so a context menu needs no selector per action.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

extension ClipboardFilter {
    /// The filter tag's label: one word, because the tag sits beside the query.
    fileprivate var shortTitle: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .image: return "Images"
        case .link: return "Links"
        case .email: return "Emails"
        }
    }
}
