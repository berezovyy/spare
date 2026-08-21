import Foundation

/// One chord: a virtual key code plus modifiers, in Carbon's encoding because that is what
/// `RegisterEventHotKey` takes. Foundation-only on purpose — the constants are ABI, so the
/// value type stays testable without AppKit, Carbon or a keyboard layout.
struct KeyShortcut: Hashable, Sendable {
    /// Carbon's modifier bits, spelled out rather than imported. These values are fixed ABI.
    static let command = 0x0100
    static let shift = 0x0200
    static let option = 0x0800
    static let control = 0x1000

    /// What the app binds until the user records something else. ⌘⇧V stays clear of
    /// Raycast's ⌥Space and of the ⌘⌥ chords Xcode and the window managers take.
    static let `default` = KeyShortcut(keyCode: 9, modifiers: command | shift)

    let keyCode: Int
    /// Masked to the four real modifiers: a device-dependent bit would break equality.
    let modifiers: Int

    /// Trusts its arguments; the validating way in is `init?(recording:modifiers:)`.
    private init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifiers
    }

    /// A chord captured from a key-down, or nil when it is not bindable: a system-wide hotkey
    /// needs ⌘, ⌥ or ⌃, else every plain `V` typed anywhere would be swallowed.
    init?(recording keyCode: Int, modifiers: Int) {
        let masked = modifiers & Self.allModifiers
        guard Self.isValidKeyCode(keyCode) else { return nil }
        guard masked & (Self.command | Self.option | Self.control) != 0 else { return nil }
        self.init(keyCode: keyCode, modifiers: masked)
    }

    /// `⌃⌥⇧⌘` in the fixed order every macOS surface uses, with the key glyph last.
    var displayString: String {
        symbols.joined()
    }

    /// One string per keycap, so the footer can draw them as separate chips.
    var symbols: [String] {
        var result: [String] = []
        if modifiers & Self.control != 0 { result.append("⌃") }
        if modifiers & Self.option != 0 { result.append("⌥") }
        if modifiers & Self.shift != 0 { result.append("⇧") }
        if modifiers & Self.command != 0 { result.append("⌘") }
        return result + [keyGlyph]
    }

    /// The key's own glyph: a fixed name for the keys that print nothing, else the ANSI
    /// character. Not the live layout — reading that needs the main thread and Carbon, and a
    /// stored chord is a key code, so a layout switch must not rewrite what the user bound.
    var keyGlyph: String {
        Self.specialGlyphs[keyCode] ?? Self.functionNames[keyCode] ?? Self.ansiCharacters[keyCode]
            ?? "?"
    }

    private static let allModifiers = command | shift | option | control

    /// Carbon virtual key codes are a single byte; anything else came from a corrupt store.
    private static func isValidKeyCode(_ keyCode: Int) -> Bool {
        (0...0x7F).contains(keyCode)
    }
}

// Persistence for `Settings.hotKey`, which is a plist string. Decoding routes through the
// validating initializer, so a hand-edited defaults entry cannot bind an unusable chord.
extension KeyShortcut: RawRepresentable {
    var rawValue: String { "\(modifiers):\(keyCode)" }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let modifiers = Int(parts[0]), let keyCode = Int(parts[1])
        else { return nil }
        self.init(recording: keyCode, modifiers: modifiers)
    }
}

extension KeyShortcut {
    /// Keys that print nothing, by Carbon virtual key code.
    private static let specialGlyphs: [Int: String] = [
        0x24: "↵", 0x4C: "⌤", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x75: "⌦", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7E: "↑", 0x7D: "↓",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟"
    ]

    private static let functionNames: [Int: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20"
    ]

    /// The ANSI block, which is what the key codes are named after in `Events.h`.
    private static let ansiCharacters: [Int: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z",
        0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
        0x0F: "R", 0x10: "Y", 0x11: "T", 0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P",
        0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N", 0x2E: "M",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9", 0x1D: "0",
        0x18: "=", 0x1B: "-", 0x21: "[", 0x1E: "]", 0x27: "'", 0x29: ";", 0x2A: "\\",
        0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`"
    ]
}
