/// Which key a ⌘-chord means, whatever the keyboard layout. Pure, so a harness can call it.
///
/// What the layout typed wins whenever it is a plain letter or digit, so a Dvorak user's ⌘P is
/// wherever P is on their keyboard. Otherwise — a Cyrillic "з", AZERTY's "&" on the 1 key — the
/// key's position on a US keyboard decides, which is what the system's own ⌘-shortcuts do.
enum ChordKey {
    /// US-layout virtual key codes for the keys the palette answers.
    private static let usLayout: [UInt16: String] = [
        0: "a", 3: "f", 6: "z", 7: "x", 8: "c", 9: "v", 35: "p",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    /// `withCommand` is `event.characters`: "Dvorak – QWERTY ⌘" switches to QWERTY only while ⌘
    /// is held, and only there. `typed` is `charactersIgnoringModifiers`.
    static func resolve(withCommand: String? = nil, typed: String?, keyCode: UInt16) -> String {
        for candidate in [withCommand, typed] {
            if let letter = latin(candidate) { return letter }
        }
        let typed = (typed ?? "").lowercased()
        // A layout typing no Latin at all (Cyrillic, Greek) borrows the US key at that position.
        // ASCII punctuation is a real key on that layout — Dvorak's ";" is not ⌘Z — except on
        // the number row, where AZERTY puts "&" over the 1.
        let isASCII = typed.unicodeScalars.allSatisfy(\.isASCII)
        if isASCII, !Self.numberRow.contains(keyCode) { return typed }
        return usLayout[keyCode] ?? typed
    }

    private static let numberRow: Set<UInt16> = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private static func latin(_ text: String?) -> String? {
        let text = (text ?? "").lowercased()
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
            scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(text)
        else { return nil }
        return text
    }
}
