import AppKit

/// The floating bar along the bottom of the panel: key hints on the left, the type filter on the
/// right. The bar itself is transparent — only the filter chip is glass.
final class FooterBar: NSView {
    /// The chosen type. Not gated on the list having rows: an over-narrow filter empties the list
    /// and this control is the only way back out of it.
    var onFilterChange: ((ClipboardFilter) -> Void)?

    private let pill = GlassPill()
    private let filterButton = NSButton(title: "", target: nil, action: nil)
    private var filter: ClipboardFilter = .all

    init() {
        super.init(frame: .zero)

        let hints = NSStackView(views: [
            Self.hint(cap: "↵", label: "Paste"),
            Self.hint(cap: "⌘P", label: "Pin"),
            Self.hint(cap: "⌘⌫", label: "Delete")
        ])
        hints.orientation = .horizontal
        hints.spacing = Theme.Spacing.lg + Theme.Spacing.md

        filterButton.bezelStyle = .inline
        filterButton.isBordered = false
        filterButton.imagePosition = .imageLeading
        filterButton.imageHugsTitle = true
        filterButton.font = Theme.Typography.keyCap()
        filterButton.contentTintColor = Theme.Colors.textSecondary
        // The search field keeps first responder: a footer control must never take it away.
        filterButton.refusesFirstResponder = true
        filterButton.target = self
        filterButton.action = #selector(showFilterMenu)
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(filterButton)
        pill.translatesAutoresizingMaskIntoConstraints = false
        hints.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hints)
        addSubview(pill)

        let margin = Theme.Spacing.lg + Theme.Spacing.md
        NSLayoutConstraint.activate([
            hints.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            hints.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: Theme.Size.keyCap + Theme.Spacing.md),
            filterButton.leadingAnchor.constraint(
                equalTo: pill.leadingAnchor, constant: Theme.Spacing.lg),
            filterButton.trailingAnchor.constraint(
                equalTo: pill.trailingAnchor, constant: -Theme.Spacing.lg),
            filterButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        apply(.all)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// States the active filter without opening the menu, the way a pop-up button does.
    func apply(_ filter: ClipboardFilter) {
        self.filter = filter
        filterButton.title = filter.title
        filterButton.image = NSImage(
            systemSymbolName: filter.systemImage, accessibilityDescription: filter.title)
        filterButton.contentTintColor =
            filter == .all ? Theme.Colors.textSecondary : Theme.Colors.textPrimary
    }

    /// `NSMenu.popUp` runs its own event-tracking mode and owns the keyboard while it is up; a
    /// custom popover is what froze input in Tinycast.
    @objc private func showFilterMenu() {
        let menu = NSMenu()
        for option in ClipboardFilter.allCases {
            let item = NSMenuItem(
                title: option.title, action: #selector(pickFilter), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = option == filter ? .on : .off
            item.image = NSImage(
                systemSymbolName: option.systemImage, accessibilityDescription: option.title)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pill.bounds.height), in: pill)
    }

    @objc private func pickFilter(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? ClipboardFilter else { return }
        apply(option)
        onFilterChange?(option)
    }

    private static func hint(cap: String, label: String) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.font = Theme.Typography.keyCap()
        text.textColor = Theme.Colors.textSecondary
        let stack = NSStackView(views: [KeyCapChip(text: cap), text])
        stack.orientation = .horizontal
        stack.spacing = Theme.Spacing.sm
        return stack
    }
}
