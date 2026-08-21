import Foundation

/// The per-channel storage roots. Keyed by bundle id so Dev never shares Release's folders.
enum AppPaths {
    /// History is the product, not a derived cache, so it lives here and never under Caches.
    static func applicationSupport(
        bundleID: String = Bundle.main.bundleIdentifier ?? "app.spare"
    ) -> URL {
        root(.applicationSupportDirectory, bundleID: bundleID)
    }

    /// For genuinely regenerable data only — the system may evict this at any time.
    static func caches(
        bundleID: String = Bundle.main.bundleIdentifier ?? "app.spare"
    ) -> URL {
        root(.cachesDirectory, bundleID: bundleID)
    }

    private static func root(
        _ directory: FileManager.SearchPathDirectory, bundleID: String
    ) -> URL {
        let url = FileManager.default
            .urls(for: directory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
