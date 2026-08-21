import AppKit

/// The one real window the app owns. Controls push into `Settings`; nothing reads back out of
/// `Settings` inside an action, because a popup's action writing the value it just read would
/// re-enter through `onChange` and loop.
@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    /// Keyed by identity, not a count: a close notification that fires twice would drive a
    /// counter negative and strand the Dock icon on forever.
    private static var openWindows: Set<ObjectIdentifier> = []

    private let settings: Settings
    private let store: ClipboardStore
    private let hotKeys: HotKeyCenter
    private let dialogs: ConfirmDialog

    private let retention = NSPopUpButton()
    private let imageBudget = NSPopUpButton()
    private let appearance = NSPopUpButton()
    private let panelPosition = NSPopUpButton()
    private let capturesImages = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let pastesPlainText = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let showsInMenuBar = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let launchAtLogin = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let ignoredApps = NSTextField(string: "")
    private let hotKeyButton = NSButton(title: "", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset Database…", target: nil, action: nil)

    /// Non-nil only while the recorder is armed; the chord is captured as a plain key-down,
    /// which is why the global registration is paused for as long as this lives.
    private var recorderMonitor: Any?

    private static let budgets = [128, 256, 512, 1_024, 2_048]

    init(
        settings: Settings, store: ClipboardStore, hotKeys: HotKeyCenter, dialogs: ConfirmDialog
    ) {
        self.settings = settings
        self.store = store
        self.hotKeys = hotKeys
        self.dialogs = dialogs
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Fills the controls from `Settings` and brings the window up as a regular app window.
    func present() {
        loadControls()
        Self.openWindows.insert(ObjectIdentifier(self))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let grid = NSGridView(views: [])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        for title in Settings.Retention.allCases.map(Self.retentionTitle) {
            retention.addItem(withTitle: title)
        }
        for budget in Self.budgets { imageBudget.addItem(withTitle: "\(budget) MB") }
        for name in Settings.Appearance.allCases { appearance.addItem(withTitle: name.title) }
        for name in Settings.PanelPosition.allCases {
            panelPosition.addItem(withTitle: name.title)
        }

        capturesImages.title = "Capture images"
        pastesPlainText.title = "Paste as plain text"
        showsInMenuBar.title = "Show icon in the menu bar"
        launchAtLogin.title = "Launch at login"
        ignoredApps.placeholderString = "com.example.app, com.other.app"

        bind(retention, #selector(retentionChanged))
        bind(imageBudget, #selector(imageBudgetChanged))
        bind(appearance, #selector(appearanceChanged))
        bind(panelPosition, #selector(panelPositionChanged))
        bind(capturesImages, #selector(capturesImagesChanged))
        bind(pastesPlainText, #selector(pastesPlainTextChanged))
        bind(showsInMenuBar, #selector(showsInMenuBarChanged))
        bind(launchAtLogin, #selector(launchAtLoginChanged))
        bind(ignoredApps, #selector(ignoredAppsChanged))
        bind(hotKeyButton, #selector(recordHotKey))

        let reveal = NSButton(title: "Reveal Data Folder", target: self, action: #selector(reveal))
        resetButton.target = self
        resetButton.action = #selector(resetDatabase)

        addRow(grid, "Shortcut", hotKeyButton)
        addRow(grid, "Keep history", retention)
        addRow(grid, "Image budget", imageBudget)
        addRow(grid, "Appearance", appearance)
        addRow(grid, "Panel opens", panelPosition)
        addRow(grid, "Ignore apps", ignoredApps)
        addRow(grid, "", capturesImages)
        addRow(grid, "", pastesPlainText)
        addRow(grid, "", showsInMenuBar)
        addRow(grid, "", launchAtLogin)
        addRow(grid, "Data", reveal)
        addRow(grid, "", resetButton)

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])
        return container
    }

    private func addRow(_ grid: NSGridView, _ label: String, _ control: NSView) {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        grid.addRow(with: [text, control])
    }

    private func bind(_ control: NSControl, _ action: Selector) {
        control.target = self
        control.action = action
    }

    // MARK: - Settings → controls

    /// Only ever called from `present`, never from an action: a control writing the value it
    /// just read is the loop this file exists to avoid.
    private func loadControls() {
        retention.selectItem(
            at: Settings.Retention.allCases.firstIndex(of: settings.retention) ?? 0)
        imageBudget.selectItem(at: Self.budgets.firstIndex(of: settings.imageBudgetMB) ?? 2)
        appearance.selectItem(
            at: Settings.Appearance.allCases.firstIndex(of: settings.appearance) ?? 0)
        panelPosition.selectItem(
            at: Settings.PanelPosition.allCases.firstIndex(of: settings.panelPosition) ?? 0)
        capturesImages.state = settings.capturesImages ? .on : .off
        pastesPlainText.state = settings.pastesPlainText ? .on : .off
        showsInMenuBar.state = settings.showsInMenuBar ? .on : .off
        launchAtLogin.state = LaunchAtLogin.isEnabled() ? .on : .off
        ignoredApps.stringValue = settings.ignoredApps.joined(separator: ", ")
        showChord()
    }

    private func showChord() {
        let chord = settings.hotKey.flatMap(KeyShortcut.init(rawValue:)) ?? .default
        hotKeyButton.title = chord.displayString
    }

    // MARK: - Controls → settings

    @objc private func retentionChanged() {
        let cases = Settings.Retention.allCases
        settings.retention = cases[min(retention.indexOfSelectedItem, cases.count - 1)]
    }

    @objc private func imageBudgetChanged() {
        let index = min(imageBudget.indexOfSelectedItem, Self.budgets.count - 1)
        settings.imageBudgetMB = Self.budgets[max(index, 0)]
    }

    @objc private func appearanceChanged() {
        let cases = Settings.Appearance.allCases
        settings.appearance = cases[min(appearance.indexOfSelectedItem, cases.count - 1)]
    }

    @objc private func panelPositionChanged() {
        let cases = Settings.PanelPosition.allCases
        settings.panelPosition = cases[min(panelPosition.indexOfSelectedItem, cases.count - 1)]
    }

    @objc private func capturesImagesChanged() {
        settings.capturesImages = capturesImages.state == .on
    }

    @objc private func pastesPlainTextChanged() {
        settings.pastesPlainText = pastesPlainText.state == .on
    }

    @objc private func showsInMenuBarChanged() {
        settings.showsInMenuBar = showsInMenuBar.state == .on
    }

    @objc private func launchAtLoginChanged() {
        LaunchAtLogin.set(launchAtLogin.state == .on)
    }

    @objc private func ignoredAppsChanged() {
        settings.ignoredApps =
            ignoredApps.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @objc private func reveal() {
        NSWorkspace.shared.open(AppPaths.applicationSupport())
    }

    /// The only path that empties history. Rows and image files go; the database file itself
    /// stays, because unlinking it under the store's open connection would leave every later
    /// write landing in a file nothing can read.
    @objc private func resetDatabase() {
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await dialogs.ask(
                "Delete all clipboard history?", confirm: "Delete", destructive: true)
            if confirmed { store.clearAll() }
        }
    }

    // MARK: - Recording

    /// Arms a local key-down monitor. The global chord is paused meanwhile, or pressing it here
    /// would summon the palette instead of being recorded.
    @objc private func recordHotKey() {
        guard recorderMonitor == nil else { return }
        hotKeyButton.title = "Type a shortcut…"
        hotKeys.isPaused = true
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.capture(event)
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        // Escape leaves the existing chord alone; anything unbindable is simply not accepted.
        if event.keyCode != 53 {
            let modifiers = Self.carbonModifiers(event.modifierFlags)
            guard let chord = KeyShortcut(recording: Int(event.keyCode), modifiers: modifiers)
            else { return }
            settings.hotKey = chord.rawValue
        }
        endRecording()
    }

    private func endRecording() {
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) }
        recorderMonitor = nil
        hotKeys.isPaused = false
        showChord()
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= KeyShortcut.command }
        if flags.contains(.shift) { result |= KeyShortcut.shift }
        if flags.contains(.option) { result |= KeyShortcut.option }
        if flags.contains(.control) { result |= KeyShortcut.control }
        return result
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        if recorderMonitor != nil { endRecording() }
        Self.openWindows.remove(ObjectIdentifier(self))
        // Only when the last real window has gone: back to an agent with no Dock tile.
        if Self.openWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    private static func retentionTitle(_ value: Settings.Retention) -> String {
        switch value {
        case .week: "1 week"
        case .month: "1 month"
        case .quarter: "3 months"
        case .forever: "Forever"
        }
    }
}

/// Display names live here rather than on the model: `Settings` is Foundation-only and these
/// are strings for a window.
extension Settings.Appearance {
    fileprivate var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

extension Settings.PanelPosition {
    fileprivate var title: String {
        switch self {
        case .cursor: "Under the cursor"
        case .center: "Centred"
        case .menuBar: "Near the menu bar"
        }
    }
}
