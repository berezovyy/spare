import AppKit
// `@preconcurrency` downgrades AX diagnostics: the option key is a constant C global.
@preconcurrency import ApplicationServices

/// The single place that asks about Accessibility, so no two callers pass different options.
enum Permissions {
    /// The trust state alone. Never prompts, so a poll or a menu redraw cannot raise a dialog.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Returns the current trust state and asks the user to grant it if it is missing.
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The system pane the prompt points at, for the second ask after the first was dismissed.
    @MainActor
    static func openSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
