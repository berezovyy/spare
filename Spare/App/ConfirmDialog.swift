import AppKit

/// A two-button confirmation that never spins a nested run loop. `NSAlert.runModal()` does, and
/// the global hotkey still fires inside it — a held chord stacks alerts until the app is unusable.
/// Two call sites: "Delete all history?" and "Accessibility is needed to paste."
@MainActor
final class ConfirmDialog: NSPanel {
    /// True from the moment a dialog is asked for until its fade-out finishes. WindowController
    /// reads it so its own resign-key does not hide the palette under this panel.
    private(set) var isPresenting = false {
        didSet { onPresentingChange?(isPresenting) }
    }

    var onPresentingChange: ((Bool) -> Void)?

    private static let width: CGFloat = 360
    private static let fadeDuration: TimeInterval = 0.09
    /// A centred box reads as low on the screen; lifting it by an eighth reads as centred.
    private static let opticalLift: CGFloat = 0.12

    private let surface = PanelSurface(frame: .zero)
    private let message = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let confirmButton = NSButton(title: "OK", target: nil, action: nil)

    /// The one piece of state the guard is keyed on. A panel mid-fade-out must not swallow the
    /// next request, so this — not `isVisible` — decides whether we are busy.
    private var continuation: CheckedContinuation<Bool, Never>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 140),
            // Non-activating, like the palette: answering must not steal the frontmost app.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the palette's `.floating`, or the question would open behind the list.
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        layOutContent()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Answers true when the user confirms. Escape, Cancel and a click away all answer false.
    func ask(_ text: String, confirm: String, destructive: Bool) async -> Bool {
        // Guarded on the continuation, not the panel: see the comment on that property.
        guard continuation == nil else { return false }
        message.stringValue = text
        confirmButton.title = confirm
        confirmButton.contentTintColor = destructive ? .systemRed : nil
        confirmButton.bezelColor = destructive ? .systemRed : nil
        isPresenting = true
        present()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    // MARK: - Layout

    private func layOutContent() {
        message.alignment = .center
        message.font = .systemFont(ofSize: 13, weight: .medium)
        message.textColor = Theme.Colors.textPrimary
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 3
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        confirmButton.target = self
        confirmButton.action = #selector(accept)

        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.spacing = Theme.Spacing.md
        let stack = NSStackView(views: [message, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.Spacing.lg * 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.autoresizingMask = [.width, .height]
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -24)
        ])
        contentView = surface
    }

    // MARK: - Presentation

    private func present() {
        let height = surface.fittingSize.height
        setFrame(centredFrame(height: max(height, 120)), display: false)
        contentView?.layoutSubtreeIfNeeded()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        makeFirstResponder(confirmButton)
        fade(to: 1)
    }

    /// The screen under the cursor, like the palette: `NSScreen.main` is the key window's screen.
    private func centredFrame(height: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let under = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let screen = under ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        return NSRect(
            x: visible.midX - Self.width / 2,
            y: visible.midY - height / 2 + visible.height * Self.opticalLift,
            width: Self.width,
            height: height)
    }

    @objc private func accept() {
        finish(true)
    }

    @objc private func cancel() {
        finish(false)
    }

    /// Resume first, fade second: the caller must be released even if the fade never completes.
    private func finish(_ answer: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: answer)
        fade(to: 0) { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
            self.isPresenting = false
        }
    }

    private func fade(to alpha: CGFloat, then finish: (@MainActor @Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { finish?() }
        }
    }

    // MARK: - Events

    /// Safe here and nowhere else in the app: this panel has no text field, so nothing is
    /// composing and no responder wants either key.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch event.keyCode {
            case 53:
                cancel()
                return
            case 36, 76:
                accept()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    /// Click-away is a cancel, the same as Escape.
    override func resignKey() {
        super.resignKey()
        if continuation != nil { cancel() }
    }
}
