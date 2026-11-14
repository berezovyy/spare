import AppKit

/// What ⌘ can do, shown only while ⌘ is held: a small glass capsule over the bottom of the list.
/// Nobody has to learn it to use the palette; anybody who holds ⌘ finds it.
final class HintBar: NSView {
    private let glass = NSGlassEffectView()
    private let pinLabel = NSTextField(labelWithString: "Pin")

    init() {
        super.init(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = Theme.Size.hintBarHeight / 2
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let hints = NSStackView(views: [
            Self.hint("⌘1–9", label(text: "Paste")),
            Self.hint("⌘P", pinLabel),
            Self.hint("⌘⌫", label(text: "Delete")),
            Self.hint("⌘C", label(text: "Copy")),
            Self.hint("⌘F", label(text: "Filter"))
        ])
        hints.orientation = .horizontal
        hints.spacing = Theme.Spacing.xl
        hints.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hints)
        style(pinLabel)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// Hints are information, never targets: clicks fall through to the row under them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// "Pin" or "Unpin", for whatever is selected right now.
    func update(selectionIsPinned: Bool) {
        pinLabel.stringValue = selectionIsPinned ? "Unpin" : "Pin"
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

    private func label(text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        style(field)
        return field
    }

    private func style(_ field: NSTextField) {
        field.font = Theme.Typography.keyCap()
        field.textColor = Theme.Colors.textSecondary
    }

    private static func hint(_ cap: String, _ label: NSTextField) -> NSView {
        let stack = NSStackView(views: [KeyCapChip(text: cap), label])
        stack.orientation = .horizontal
        stack.spacing = Theme.Spacing.sm
        return stack
    }
}
