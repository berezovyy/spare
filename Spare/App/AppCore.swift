import AppKit

/// The one owner. Ownership is a tree — every object below is held here and nowhere else, and
/// every back-reference into this object is `weak`. AppDelegate holds exactly one of these.
@MainActor
final class AppCore {
    /// Set by StatusItem, which owns the menu-bar item this projects onto. A closure rather
    /// than a reference, so this file compiles before the menu bar exists.
    var onMenuBarVisibilityChange: ((Bool) -> Void)?

    let settings = Settings()
    let store: ClipboardStore
    let windowController: WindowController

    private let monitor: ClipboardMonitor
    private let hotKeys = HotKeyCenter()
    private let dialogs = ConfirmDialog()

    /// Built on first use: a window nobody opens should cost nothing at launch.
    private var settingsWindow: SettingsWindow?

    /// Whatever was frontmost when the palette was summoned, so a paste lands back there.
    private var pasteTarget: NSRunningApplication?

    init() {
        // `AppPaths` keys on the bundle id, so a Debug build writes under `app.spare.dev`.
        store = ClipboardStore(directory: AppPaths.applicationSupport())
        windowController = WindowController(store: store)
        monitor = ClipboardMonitor(store: store, settings: settings)
    }

    /// Every connection in the app, in one place. Called once, from `didFinishLaunching`.
    func start() {
        settings.onChange = { [weak self] key in
            guard let self else { return }
            switch key {
            case .retentionDays:
                applyRetention()
                store.enforceLimits()
            case .imageBudgetMB:
                store.imageBudget = settings.imageBudgetMB * 1_024 * 1_024
                store.enforceLimits()
            case .appearance:
                NSApp.appearance = settings.appearance.nsAppearance
            case .showsInMenuBar:
                onMenuBarVisibilityChange?(settings.showsInMenuBar)
            case .hotKey:
                hotKeys.rebind(boundShortcut())
            // Read at the point of use: the monitor re-reads `ignoredApps` every poll, and the
            // rest are consulted when the palette opens. An exhaustive switch so a new key does
            // not compile until someone has decided which of the two it is.
            case .ignoredApps, .capturesImages, .pastesPlainText, .panelPosition:
                break
            }
        }

        hotKeys.onPress = { [weak self] in self?.toggle() }
        windowController.onActivate = { [weak self] in self?.activate($0) }
        dialogs.onPresentingChange = { [weak self] in
            self?.windowController.isPresentingDialog = $0
        }

        applyRetention()
        store.imageBudget = settings.imageBudgetMB * 1_024 * 1_024
        NSApp.appearance = settings.appearance.nsAppearance
        hotKeys.rebind(boundShortcut())

        // Never synchronous on the launch path: opening is cheap, reading every row is not.
        Task { store.load() }
        monitor.start()
    }

    /// `forever` is nil age; the store spells "never trim" as an unreachable maximum.
    private func applyRetention() {
        store.maxAge = settings.retention.maxAge ?? .greatestFiniteMagnitude
    }

    func showSettings() {
        let window =
            settingsWindow
            ?? SettingsWindow(
                settings: settings, store: store, hotKeys: hotKeys, dialogs: dialogs)
        settingsWindow = window
        window.present()
    }

    /// Captured before the palette takes focus; a paste has to know where to land.
    private func toggle() {
        if !windowController.isVisible {
            pasteTarget = NSWorkspace.shared.frontmostApplication
        }
        windowController.toggle()
    }

    private func activate(_ item: ClipboardItem) {
        let target = pasteTarget
        windowController.hide(restoreFocus: false)
        store.promote(item)
        guard Permissions.isTrusted() else {
            Paster.copy(item, store: store)
            askForAccessibility()
            return
        }
        Paster.paste(item, store: store, into: target)
    }

    private func askForAccessibility() {
        Task {
            let open = await dialogs.ask(
                "Accessibility is needed to paste. The clip was copied instead.",
                confirm: "Open Settings", destructive: false)
            if open { Permissions.openSettings() }
        }
    }

    /// A stored chord, else the shipped default. An unbindable stored value falls back rather
    /// than leaving the app with no hotkey at all.
    private func boundShortcut() -> KeyShortcut {
        settings.hotKey.flatMap(KeyShortcut.init(rawValue:)) ?? .default
    }
}

/// The AppKit half of a Foundation-only setting; `Settings` deliberately stores a string.
extension Settings.Appearance {
    fileprivate var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}
