// Standalone test for the preferences layer, against a throwaway suite: the real defaults domain
// belongs to the installed app, and a harness that writes it corrupts a running Spare's state.
import Foundation

@main
@MainActor
struct SettingsTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        unsetDefaultTrueFlagReadsAsItsFallback()
        storedFalseSurvivesAsAStoredFalse()
        aWriteNotifiesWithItsOwnKey()
        resetClearsEveryKey()
        rawValuesAreTheStoredStrings()
        arraysRoundTrip()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    /// `register(defaults:)` would make this pass while breaking the next case, so both must run.
    static func unsetDefaultTrueFlagReadsAsItsFallback() {
        withScratchDefaults { defaults, name in
            let settings = Settings(defaults: defaults)
            expect(settings.capturesImages, "an unset default-true flag reads true")
            expect(
                defaults.object(forKey: SettingsKey.capturesImages.rawValue) == nil,
                "reading a fallback stores nothing in \(name)")
        }
    }

    /// The distinction the whole no-`register` rule exists to protect.
    static func storedFalseSurvivesAsAStoredFalse() {
        withScratchDefaults { defaults, _ in
            let settings = Settings(defaults: defaults)
            settings.capturesImages = false
            expect(
                defaults.object(forKey: SettingsKey.capturesImages.rawValue) != nil,
                "a stored false is present on disk")

            let reloaded = Settings(defaults: defaults)
            expect(!reloaded.capturesImages, "a stored false reads back as false, not the fallback")
        }
    }

    /// One sink switches on the key, so the wrong key re-projects the wrong thing.
    static func aWriteNotifiesWithItsOwnKey() {
        withScratchDefaults { defaults, _ in
            let settings = Settings(defaults: defaults)
            var seen: [SettingsKey] = []
            settings.onChange = { seen.append($0) }

            settings.pastesPlainText = true
            settings.retention = .week

            expect(seen == [.pastesPlainText, .retentionDays], "each write named its own key")
        }
    }

    /// Reset is a removal, not a write of the fallbacks: the keys must be gone afterwards.
    static func resetClearsEveryKey() {
        withScratchDefaults { defaults, _ in
            let settings = Settings(defaults: defaults)
            settings.capturesImages = false
            settings.showsInMenuBar = false
            settings.retention = .forever
            settings.ignoredApps = ["com.example.app"]
            settings.hotKey = "cmd-shift-v"

            settings.reset()

            for key in SettingsKey.allCases {
                expect(
                    defaults.object(forKey: key.rawValue) == nil, "reset removed \(key.rawValue)")
            }
            expect(settings.capturesImages, "capturesImages is back to its fallback")
            expect(settings.showsInMenuBar, "showsInMenuBar is back to its fallback")
            expect(settings.retention == .month, "retention is back to its fallback")
            expect(settings.ignoredApps.isEmpty, "ignoredApps is back to its fallback")
            expect(settings.hotKey == nil, "hotKey is back to unset")
        }
    }

    /// Locks the strings on disk: a Swift rename must never orphan a user's stored preference.
    static func rawValuesAreTheStoredStrings() {
        let expected = [
            "retentionDays", "ignoredApps", "capturesImages", "imageBudgetMB",
            "pastesPlainText", "showsInMenuBar", "appearance", "panelPosition", "hotKey"
        ]
        expect(
            SettingsKey.allCases.map(\.rawValue) == expected,
            "the stored key strings are unchanged")
    }

    static func arraysRoundTrip() {
        withScratchDefaults { defaults, _ in
            let settings = Settings(defaults: defaults)
            settings.ignoredApps = ["com.apple.Terminal", "com.example.vault"]

            let reloaded = Settings(defaults: defaults)
            expect(
                reloaded.ignoredApps == ["com.apple.Terminal", "com.example.vault"],
                "an array survives a write and a fresh read")
        }
    }

    // MARK: - Helpers

    /// A suite named per run, torn down after: never `.standard`, never `app.spare[.dev]`.
    static func withScratchDefaults(_ body: (UserDefaults, String) -> Void) {
        let name = "app.spare.settings-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            expect(false, "could not open the scratch suite \(name)")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults, name)
    }

    static func expect(
        _ condition: Bool, _ label: String, fileID: String = #fileID, line: Int = #line
    ) {
        if condition {
            passes += 1
        } else {
            print("FAIL: \(label) (\(fileID):\(line))")
            failures += 1
        }
    }
}
