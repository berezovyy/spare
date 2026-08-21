import AppKit

/// The menu-bar icon and its menu. The one place the app is reachable without a hotkey, which
/// is why it is also the only surface that can be switched off (`showsInMenuBar`).
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    /// Held strongly: the status bar keeps no reference of its own, so a released item takes
    /// the icon out of the menu bar with it.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private let core: AppCore

    init(core: AppCore) {
        self.core = core
        super.init()

        item.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: Self.appName
        )
        // Inverts correctly under a dark menu bar; a coloured icon would not.
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        item.isVisible = core.settings.showsInMenuBar

        // Weak on the item, not on self: AppCore outlives this object and the closure is the
        // only edge back, so a strong capture here would keep a dead status item alive.
        core.onMenuBarVisibilityChange = { [weak item] in item?.isVisible = $0 }
    }

    /// `Spare` or `Spare Dev`, so the Debug channel says which app is about to quit.
    private static var appName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleName"] as? String ?? "Spare"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(entry("Open \(Self.appName)", #selector(open), key: ""))
        menu.addItem(entry("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(entry("Quit \(Self.appName)", #selector(quit), key: "q"))
        return menu
    }

    private func entry(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func open() {
        core.windowController.show()
    }

    @objc private func showSettings() {
        core.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
