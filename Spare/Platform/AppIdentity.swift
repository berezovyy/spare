import AppKit

/// What a row shows for the app a clip came from: its real name and icon, resolved from the
/// bundle id the monitor stored. Memoised — a reload asks for every visible row, and a Launch
/// Services lookup per row per keystroke would be the slowest thing in the palette.
@MainActor
enum AppIdentity {
    struct Entry {
        let name: String
        let icon: NSImage?
    }

    /// Bounded only by the number of apps a person copies from, which is a handful.
    private static var cache: [String: Entry] = [:]

    static func entry(for bundleID: String?) -> Entry? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let hit = cache[bundleID] { return hit }
        let entry: Entry
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            entry = Entry(
                name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                icon: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            // Uninstalled since the copy: the id's last component is still better than nothing.
            let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            entry = Entry(name: tail.prefix(1).uppercased() + tail.dropFirst(), icon: nil)
        }
        cache[bundleID] = entry
        return entry
    }
}
