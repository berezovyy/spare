// Standalone test for the storage roots, compiling the real source rather than a copy.
import Foundation

@main
@MainActor
struct AppPathsTests {
    static var failures = 0
    static var passes = 0

    // Never the no-argument form: under swiftc `Bundle.main` is this harness, not Spare.
    private static let devID = "app.spare.dev"
    private static let releaseID = "app.spare"
    private static let scratchID = "app.spare.dev.test"

    static func main() {
        channelsDoNotShareAFolder()
        lastComponentIsTheWholeID()
        directoryIsCreatedIfMissing()
        cachesIsASeparateRoot()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    /// The Debug channel is the reason this seam exists: Dev must never write into Release's dir.
    static func channelsDoNotShareAFolder() {
        withoutCreating(devID) { dev in
            withoutCreating(releaseID) { release in
                expect(
                    dev.path.contains("Application Support"),
                    "dev root is under Application Support, not Caches")
                expect(
                    release.path.contains("Application Support"),
                    "release root is under Application Support, not Caches")
                expect(dev.path.contains(devID), "dev root names the dev bundle id")
                expect(!release.path.contains(".dev"), "release root carries no dev marker")
                expect(dev.path != release.path, "the two channels get different folders")
                expect(
                    dev.deletingLastPathComponent().path
                        == release.deletingLastPathComponent().path,
                    "both hang off the same Application Support parent")
            }
        }
    }

    /// A prefix collision (`app.spare` vs `app.spare.dev`) would have the channels share a folder.
    static func lastComponentIsTheWholeID() {
        withoutCreating(devID) { dev in
            withoutCreating(releaseID) { release in
                expect(dev.lastPathComponent == devID, "dev folder is exactly the id")
                expect(release.lastPathComponent == releaseID, "release folder is exactly the id")
                expect(
                    !dev.path.hasPrefix(release.path + "/"),
                    "dev is not nested inside the release folder")
            }
        }
    }

    /// A missing root must be created, or the first write of a clean install fails.
    static func directoryIsCreatedIfMissing() {
        let manager = FileManager.default
        let probe = AppPaths.applicationSupport(bundleID: scratchID)
        try? manager.removeItem(at: probe)
        expect(!manager.fileExists(atPath: probe.path), "scratch root starts absent")

        let url = AppPaths.applicationSupport(bundleID: scratchID)
        defer { try? manager.removeItem(at: url) }

        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        expect(exists, "the root is created on demand")
        expect(isDirectory.boolValue, "and it is a directory")
        expect(url.lastPathComponent == scratchID, "scratch root is named for the injected id")
    }

    /// `caches` stays available for regenerable data, and is a different root from history's.
    static func cachesIsASeparateRoot() {
        let manager = FileManager.default
        let existed = manager.fileExists(atPath: cachesProbe.path)
        let cache = AppPaths.caches(bundleID: scratchID)
        defer { if !existed { try? manager.removeItem(at: cache) } }

        expect(cache.lastPathComponent == scratchID, "cache root is named for the injected id")
        expect(!cache.path.contains("Application Support"), "caches is not Application Support")
        expect(
            cache.path != AppPaths.applicationSupport(bundleID: scratchID).path,
            "history and caches are distinct roots")
        try? manager.removeItem(at: AppPaths.applicationSupport(bundleID: scratchID))
    }

    private static var cachesProbe: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(scratchID, isDirectory: true)
    }

    // MARK: - Helpers

    /// Calls the seam for a real channel id but leaves no folder behind that was not already there.
    static func withoutCreating(_ bundleID: String, _ body: (URL) -> Void) {
        let manager = FileManager.default
        let expected =
            manager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        let existed = manager.fileExists(atPath: expected.path)
        let url = AppPaths.applicationSupport(bundleID: bundleID)
        body(url)
        // Only ever remove a folder this harness itself created, never a real history folder.
        if !existed { try? manager.removeItem(at: url) }
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
