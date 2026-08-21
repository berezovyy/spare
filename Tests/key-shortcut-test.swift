// Standalone test for the chord value type. Foundation only: if this harness ever needs AppKit
// or Carbon to compile, a display or registration concern has leaked into a stored value.
import Foundation

@main
@MainActor
struct KeyShortcutTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        theDefaultChordIsCommandShiftV()
        rawValueRoundTrips()
        aChordWithoutACommandingModifierIsRejected()
        malformedRawValuesAreRejected()
        deviceBitsDoNotBreakEquality()
        equalityIsModifiersAndKeyTogether()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    static func theDefaultChordIsCommandShiftV() {
        let chord = KeyShortcut.default
        expect(
            chord.displayString == "⇧⌘V",
            "the default renders as ⇧⌘V, not \(chord.displayString)")
        expect(chord.symbols == ["⇧", "⌘", "V"], "each keycap is its own string")
        expect(chord.keyCode == 9, "V is Carbon key code 9")
    }

    /// `Settings.hotKey` is a plist string, so this is the whole persistence path.
    static func rawValueRoundTrips() {
        let chord = KeyShortcut.default
        guard let decoded = KeyShortcut(rawValue: chord.rawValue) else {
            expect(false, "the default's raw value \(chord.rawValue) decodes")
            return
        }
        expect(decoded == chord, "a chord survives encode and decode")

        guard let f13 = KeyShortcut(recording: 0x69, modifiers: KeyShortcut.control),
            let decodedF13 = KeyShortcut(rawValue: f13.rawValue)
        else {
            expect(false, "⌃F13 records and decodes")
            return
        }
        expect(decodedF13 == f13, "a function-key chord round-trips too")
        expect(decodedF13.displayString == "⌃F13", "and still names its key")
    }

    /// A system-wide hotkey without ⌘, ⌥ or ⌃ would eat a plain keystroke everywhere.
    static func aChordWithoutACommandingModifierIsRejected() {
        expect(KeyShortcut(recording: 9, modifiers: 0) == nil, "a bare key is not bindable")
        expect(
            KeyShortcut(recording: 9, modifiers: KeyShortcut.shift) == nil,
            "⇧ alone is not a commanding modifier")
        expect(
            KeyShortcut(recording: 0x7F + 1, modifiers: KeyShortcut.command) == nil,
            "a key code outside the Carbon byte is rejected")
    }

    static func malformedRawValuesAreRejected() {
        expect(KeyShortcut(rawValue: "") == nil, "an empty stored shortcut is invalid")
        expect(KeyShortcut(rawValue: "768") == nil, "a raw value missing its key code is invalid")
        expect(KeyShortcut(rawValue: "768:v") == nil, "a non-numeric key code is invalid")
        expect(KeyShortcut(rawValue: "0:9") == nil, "a stored bare key does not decode")
    }

    /// Caps lock and the numeric-pad bit ride along on a real key-down event.
    static func deviceBitsDoNotBreakEquality() {
        let clean = KeyShortcut(recording: 9, modifiers: KeyShortcut.command)
        let noisy = KeyShortcut(recording: 9, modifiers: KeyShortcut.command | 0x2000 | 0x0400)
        expect(clean != nil && clean == noisy, "unmasked device bits are dropped")
    }

    static func equalityIsModifiersAndKeyTogether() {
        let cmdV = KeyShortcut(recording: 9, modifiers: KeyShortcut.command)
        let bothModifiers = KeyShortcut.command | KeyShortcut.shift
        let cmdShiftV = KeyShortcut(recording: 9, modifiers: bothModifiers)
        let cmdB = KeyShortcut(recording: 0x0B, modifiers: KeyShortcut.command)
        expect(
            cmdV == KeyShortcut(recording: 9, modifiers: KeyShortcut.command),
            "the same modifiers and key make the same chord")
        expect(cmdV != cmdShiftV, "a different modifier set is a different chord")
        expect(cmdV != cmdB, "a different key is a different chord")
        expect(cmdShiftV?.displayString == "⇧⌘V", "modifiers render in ⌃⌥⇧⌘ order")
    }

    // MARK: - Helpers

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
