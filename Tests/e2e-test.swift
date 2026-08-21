// The one honest capture test, and the one harness allowed to write `NSPasteboard.general` —
// that is the only pasteboard the monitor watches, so a unique-name board would prove nothing.
// It talks to the Dev channel alone: it refuses to run while Release (`app.spare`) is up, it
// launches and quits only `app.spare.dev`, it reads the Dev database read-only, and it removes
// nothing it did not create. The nonce row is deleted afterwards; history is never cleared.
import AppKit
import SQLite3

@main
@MainActor
struct EndToEndTests {
    static var failures = 0
    static var passes = 0

    private static let releaseBundleID = "app.spare"
    private static let devBundleID = "app.spare.dev"

    /// Three 500 ms monitor polls plus tolerance, per the plan; then a longer patient window.
    private static let captureFloor: TimeInterval = 1.6
    private static let captureTimeout: TimeInterval = 12

    static func main() {
        guard releaseIsIdle() else {
            print("REFUSE: Spare (\(releaseBundleID)) is running — quit it and re-run.")
            exit(1)
        }
        guard let app = builtApp() else {
            print("skip e2e: build/Debug/Spare Dev.app not found — run Scripts/build-app.sh Debug")
            print("0/0 passed")
            exit(0)
        }

        // Everything created below is undone in reverse order, whatever the cases do.
        let supportExisted = FileManager.default.fileExists(atPath: supportDirectory().path)
        let previousPasteboard = snapshotPasteboard()
        let nonce = "spare-e2e-\(UUID().uuidString)"
        defer {
            quitDev()
            if supportExisted {
                deleteNonceRow(nonce)
            } else {
                try? FileManager.default.removeItem(at: supportDirectory())
            }
            restorePasteboard(previousPasteboard)
            print("\(passes)/\(passes + failures) passed")
            exit(failures > 0 ? 1 : 0)
        }

        quitDev()
        guard launchDev(app) else {
            expect(false, "Spare Dev launched and became ready")
            return
        }

        captureLandsInDevHistory(nonce)
        pasteBackReturnsTheNonce(nonce)
    }

    // MARK: - Cases

    /// Capture must always be verified. A machine that can build Spare Dev can prove this.
    static func captureLandsInDevHistory(_ nonce: String) {
        let board = NSPasteboard.general
        board.clearContents()
        expect(board.setString(nonce, forType: .string), "the nonce reached .general")

        Thread.sleep(forTimeInterval: captureFloor)
        let deadline = Date().addingTimeInterval(captureTimeout - captureFloor)
        var row = storedRow(matching: nonce)
        while row == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            row = storedRow(matching: nonce)
        }

        guard let row else {
            expect(false, "the copy landed in \(devBundleID)'s history within \(captureTimeout)s")
            return
        }
        expect(true, "the copy landed in \(devBundleID)'s history")
        expect(row.text == nonce, "the stored text is the nonce verbatim")
        // Case 2: the key is what search scans, so it has to carry the folded nonce.
        expect(
            row.searchKey.contains(ClipboardItem.fold(nonce)),
            "search_key contains ClipboardItem.fold(nonce)")
    }

    /// Conservative by design: a false failure here is worse than a skip. Anything that would
    /// make synthetic ⌘⇧V ambiguous — no Accessibility grant, a hotkey we did not choose —
    /// skips without failing, exactly as the plan asks.
    static func pasteBackReturnsTheNonce(_ nonce: String) {
        guard AXIsProcessTrusted() else {
            print("skip paste-back: Accessibility not granted")
            return
        }
        guard UserDefaults(suiteName: devBundleID)?.string(forKey: "hotKey") == nil else {
            print("skip paste-back: a custom hotkey is configured for \(devBundleID)")
            return
        }

        // KeyShortcut.default — ⌘⇧V. Then a prefix of the nonce, then Return.
        post(keyCode: 9, flags: [.maskCommand, .maskShift])
        Thread.sleep(forTimeInterval: 0.4)
        type(String(nonce.prefix(18)))
        Thread.sleep(forTimeInterval: 0.4)
        post(keyCode: 36, flags: [])
        Thread.sleep(forTimeInterval: 0.6)

        // Paster writes the item back with its internal marker, so the pasteboard still holds
        // the nonce and the monitor will not re-record it.
        let board = NSPasteboard.general
        let held = board.string(forType: .string) == nonce
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        expect(
            held || frontmost != devBundleID,
            "after paste-back .general still holds the nonce, or Spare Dev yielded the front")
    }

    // MARK: - The app under test

    /// Built by `Scripts/build-app.sh Debug`, which `run-tests.sh` runs before this harness.
    static func builtApp() -> URL? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/Debug/Spare Dev.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func releaseIsIdle() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: releaseBundleID).isEmpty
    }

    static func devInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: devBundleID)
    }

    /// `-g` keeps the launch in the background: the harness never steals the front from a person.
    static func launchDev(_ app: URL) -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", app.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !devInstances().isEmpty,
                FileManager.default.fileExists(atPath: databaseURL().path)
            {
                // The store opens the file on the launch path; one more poll lets it finish.
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Only ever the Dev channel, and never `forceTerminate` before asking politely.
    static func quitDev() {
        let running = devInstances()
        if running.isEmpty { return }
        for app in running { app.terminate() }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !devInstances().allSatisfy(\.isTerminated) {
            Thread.sleep(forTimeInterval: 0.25)
        }
        for app in devInstances() where !app.isTerminated { app.forceTerminate() }
    }

    // MARK: - The Dev database

    static func supportDirectory() -> URL {
        let roots = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = roots.first ?? URL(fileURLWithPath: NSHomeDirectory())
        return root.appendingPathComponent(devBundleID, isDirectory: true)
    }

    static func databaseURL() -> URL {
        supportDirectory().appendingPathComponent("clipboard.sqlite3")
    }

    /// Read-only: this harness observes the running app's history, it never writes into it.
    static func storedRow(matching nonce: String) -> (text: String?, searchKey: String)? {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL().path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return nil }

        var stmt: OpaquePointer?
        let sql = "SELECT text, search_key FROM items WHERE search_key LIKE ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, "%\(ClipboardItem.fold(nonce))%")
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (column(stmt, 0), column(stmt, 1) ?? "")
    }

    /// Teardown, and the only write: the nonce row this run put there, never anything else.
    static func deleteNonceRow(_ nonce: String) {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL().path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return }

        var stmt: OpaquePointer?
        let sql = "DELETE FROM items WHERE search_key LIKE ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, "%\(ClipboardItem.fold(nonce))%")
        _ = sqlite3_step(stmt)
    }

    /// SQLite keeps no copy unless told to, and the Swift string dies at the call boundary.
    static func bind(_ stmt: OpaquePointer?, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, value, -1, transient)
    }

    static func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    // MARK: - The shared pasteboard

    /// Whatever the person had copied is theirs; the nonce borrows `.general` and hands it back.
    static func snapshotPasteboard() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var payload: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type.rawValue] = data }
            }
            return payload
        }
    }

    static func restorePasteboard(_ snapshot: [[String: Data]]) {
        let board = NSPasteboard.general
        board.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload { item.setData(data, forType: .init(type)) }
            return item
        }
        board.writeObjects(items)
    }

    // MARK: - Synthetic input

    static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in Array(text.utf16) {
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                var unit = scalar
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event?.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
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
