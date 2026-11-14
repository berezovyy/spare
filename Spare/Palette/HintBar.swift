import AppKit

/// A small glass capsule of keycaps and words, floating just under the palette. Information,
/// never a target: clicks fall through it.
class GlassCapsule: NSView {
    private let glass = NSGlassEffectView()
    /// Small glass takes on the darkness of whatever is behind it however it is tinted, so the
    /// contrast comes from a fill of its own laid over the glass.
    private let fill = NSView()

    init(_ items: [NSView]) {
        super.init(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = Theme.Size.hintBarHeight / 2
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        fill.wantsLayer = true
        fill.layer?.cornerRadius = Theme.Size.hintBarHeight / 2
        fill.layer?.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)

        let hints = NSStackView(views: items)
        hints.orientation = .horizontal
        hints.spacing = Theme.Spacing.xl
        hints.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hints)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            hints.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.xl),
            hints.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.xl),
            hints.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.Size.hintBarHeight)
        ])
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Resolved per appearance for the reason `PanelSurface` gives.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.layer?.backgroundColor = Theme.Colors.capsuleFill.cgColor
        }
    }

    /// Bumped by every call, so a fade-out that finishes after a newer fade-in leaves it alone.
    private var generation = 0

    func setVisible(_ visible: Bool) {
        generation += 1
        let current = generation
        if visible { isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.hintFade
            context.timingFunction = visible ? Theme.Motion.easeOut : Theme.Motion.easeIn
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !visible, self.generation == current else { return }
                // Hidden, not just transparent: glass is composited apart from the view's alpha,
                // so a zero-alpha capsule is not guaranteed to be gone.
                self.isHidden = true
            }
        }
    }

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Theme.Typography.keyCap()
        field.textColor = Theme.Colors.textSecondary
        return field
    }

    /// A keycap followed by what it does.
    static func hint(_ cap: String, _ label: NSTextField) -> NSView {
        let stack = NSStackView(views: [KeyCapChip(text: cap), label])
        stack.orientation = .horizontal
        stack.spacing = Theme.Spacing.sm
        return stack
    }
}

/// What ⌘ can do, shown only while ⌘ is held. Nobody has to learn it to use the palette;
/// anybody who holds ⌘ finds it.
final class HintBar: GlassCapsule {
    private let pinLabel = GlassCapsule.label("Pin")

    init() {
        super.init([
            Self.hint("⌘1–9", Self.label("Paste")),
            Self.hint("⌘P", pinLabel),
            Self.hint("⌘⌫", Self.label("Delete")),
            Self.hint("⌘C", Self.label("Copy")),
            Self.hint("⌘F", Self.label("Filter"))
        ])
    }

    /// "Pin" or "Unpin", for whatever is selected right now.
    func update(selectionIsPinned: Bool) {
        pinLabel.stringValue = selectionIsPinned ? "Unpin" : "Pin"
    }
}

/// Shown for a few seconds after a delete: the one way back from ⌘⌫, said where the eye is.
final class UndoToast: GlassCapsule {
    init() {
        let deleted = GlassCapsule.label("Deleted")
        deleted.textColor = Theme.Colors.textPrimary
        super.init([deleted, Self.hint("⌘Z", Self.label("Undo"))])
    }
}
