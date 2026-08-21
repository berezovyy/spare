import Foundation

/// Every persisted key, spelled out so renaming a case can never rename a stored key.
/// `launchAtLogin` is absent on purpose: SMAppService owns the login item, not UserDefaults.
enum SettingsKey: String, CaseIterable {
    case retentionDays = "retentionDays"
    case ignoredApps = "ignoredApps"
    case capturesImages = "capturesImages"
    case imageBudgetMB = "imageBudgetMB"
    case pastesPlainText = "pastesPlainText"
    case showsInMenuBar = "showsInMenuBar"
    case appearance = "appearance"
    case panelPosition = "panelPosition"
    case hotKey = "hotKey"
}

/// The persisted preferences, read once into memory and written back through one helper.
@MainActor
final class Settings {
    /// How long a clip survives. `forever` is 0 days, which is why the raw value is the day count.
    enum Retention: Int, CaseIterable, Sendable {
        case week = 7
        case month = 30
        case quarter = 90
        case forever = 0

        /// Seconds a clip may live, or nil when history is never trimmed by age.
        var maxAge: TimeInterval? {
            self == .forever ? nil : TimeInterval(rawValue) * 86_400
        }
    }

    /// Stored as a string so this file stays Foundation-only; AppKit maps it at the use site.
    enum Appearance: String, CaseIterable, Sendable {
        case system
        case dark
        case light
    }

    /// Where the panel shows up on the screen it opens on.
    enum PanelPosition: String, CaseIterable, Sendable {
        case cursor
        case center
        case menuBar
    }

    /// Fires after the write lands. One sink switches exhaustively, so a new key does not
    /// compile until someone has decided what it re-projects.
    var onChange: ((SettingsKey) -> Void)?

    var retention: Retention { didSet { write(.retentionDays, retention.rawValue) } }
    var ignoredApps: [String] { didSet { write(.ignoredApps, ignoredApps) } }
    var capturesImages: Bool { didSet { write(.capturesImages, capturesImages) } }
    var imageBudgetMB: Int { didSet { write(.imageBudgetMB, imageBudgetMB) } }
    var pastesPlainText: Bool { didSet { write(.pastesPlainText, pastesPlainText) } }
    var showsInMenuBar: Bool { didSet { write(.showsInMenuBar, showsInMenuBar) } }
    var appearance: Appearance { didSet { write(.appearance, appearance.rawValue) } }
    var panelPosition: PanelPosition { didSet { write(.panelPosition, panelPosition.rawValue) } }
    /// nil means "never bound", which is not the same as a shortcut the user cleared.
    var hotKey: String? { didSet { write(.hotKey, hotKey) } }

    private let defaults: UserDefaults

    /// Set while properties are being filled from `defaults`, so a load never writes back.
    private var isLoading = false

    /// `defaults` is injected so a harness can pass a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        retention = .month
        ignoredApps = []
        capturesImages = true
        imageBudgetMB = 512
        pastesPlainText = false
        showsInMenuBar = true
        appearance = .system
        panelPosition = .cursor
        hotKey = nil
        load()
    }

    /// Clears every stored key and returns the in-memory values to their fallbacks.
    func reset() {
        for key in SettingsKey.allCases { defaults.removeObject(forKey: key.rawValue) }
        load()
        for key in SettingsKey.allCases { onChange?(key) }
    }

    // MARK: - Reading

    /// Fallbacks are inlined here rather than registered, so an unset key stays absent on disk.
    private func load() {
        isLoading = true
        defer { isLoading = false }

        let days = defaults.object(forKey: SettingsKey.retentionDays.rawValue) as? Int
        retention = days.flatMap(Retention.init(rawValue:)) ?? .month
        ignoredApps = defaults.object(forKey: SettingsKey.ignoredApps.rawValue) as? [String] ?? []
        capturesImages = flag(.capturesImages, default: true)
        imageBudgetMB = defaults.object(forKey: SettingsKey.imageBudgetMB.rawValue) as? Int ?? 512
        pastesPlainText = flag(.pastesPlainText, default: false)
        showsInMenuBar = flag(.showsInMenuBar, default: true)
        appearance = named(.appearance) ?? .system
        panelPosition = named(.panelPosition) ?? .cursor
        hotKey = defaults.object(forKey: SettingsKey.hotKey.rawValue) as? String
    }

    /// Absence must be told apart from a stored `false`, which `bool(forKey:)` alone cannot do.
    private func flag(_ key: SettingsKey, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    /// A string-backed case, or nil when the key is unset or names a case we no longer ship.
    private func named<Value: RawRepresentable>(_ key: SettingsKey) -> Value?
    where Value.RawValue == String {
        (defaults.object(forKey: key.rawValue) as? String).flatMap(Value.init(rawValue:))
    }

    // MARK: - Writing

    /// A nil value removes the key, so "never set" stays distinguishable from a stored default.
    private func write(_ key: SettingsKey, _ value: Any?) {
        guard !isLoading else { return }
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
        onChange?(key)
    }
}
