import AppKit

/// The query field. Navigation keys are routed through `doCommandBy:` rather than intercepted in
/// `sendEvent`, so an IME gets first refusal and a live composition keeps Escape, arrows and Return.
final class SearchField: NSTextField, NSTextFieldDelegate {
    /// The query after every keystroke. No debounce: a scan over history is sub-millisecond.
    var onQueryChange: (String) -> Void = { _ in }
    /// -1 for up, +1 for down. ⌃P / ⌃N arrive here too, from the standard key-binding table.
    var onMove: (Int) -> Void = { _ in }
    /// Return: paste the selected row.
    var onActivate: () -> Void = {}
    /// Escape, and ⌘. which sends the same selector.
    var onCancel: () -> Void = {}
    /// Backspace on an already-empty query. Returns true when it consumed the key.
    var onBackOut: () -> Bool = { false }

    init(placeholder: String) {
        super.init(frame: .zero)
        // AppKit owns marked-text interaction, so the placeholder is its business, not ours.
        placeholderString = placeholder
        font = Theme.Typography.searchField()
        textColor = Theme.Colors.textPrimary
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange(stringValue)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onMove(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            onMove(+1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onActivate()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // A bare backspace on an empty query backs out of the screen; otherwise it edits.
            return stringValue.isEmpty ? onBackOut() : false
        default:
            return false
        }
    }
}
