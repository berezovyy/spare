// Standalone test for the store. Every case owns a scratch directory it creates and removes, and
// `ClipboardStore(directory:)` takes no default — the real database is unreachable from here.
// No pasteboard: text goes in as strings, images as bytes.
import Foundation

@main
@MainActor
struct ClipboardTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        pinOrderIsPinTimeNotRecency()
        unpinRejoinsAsNewest()
        promoteLeavesAPinInPlace()
        pinsSurvivePruneAndTheWindow()
        pinsLeadFilteredSearch()
        typeFilterSplitsHistory()
        theMemoIncludesTheFilter()
        pinOrderIsRestoredFromDisk()
        clearAllEmptiesRowsAndFiles()
        aDatabaseThatWillNotOpenIsKept()
        foldedSubstringSurvivesAReload()
        imagesAreFilesNotBlobs()
        aDeleteCanBeUndone()
        anOrphanedImageIsSweptOnLoad()
        undoAfterTheSamePictureReturnsKeepsOneCopy()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    /// The Pinned block is ordered by when each row was pinned, so a pin never jumps its elders.
    static func pinOrderIsPinTimeNotRecency() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("first", sourceApp: nil)
        store.addText("second", sourceApp: nil)
        guard let older = store.items.last, let newer = store.items.first else {
            return expect(false, "two rows recorded")
        }
        store.togglePinned(older)
        store.togglePinned(newer)
        let rows = store.search("", filter: .all)
        expect(rows.count == 2, "no row duplicated by pinning")
        expect(rows.first?.text == "first", "the first pin leads, though it is the older copy")
        expect(rows.last?.text == "second", "the second pin joins below the first")
    }

    /// Unpinning is not "put it back where it was": the row rejoins the history as the newest.
    static func unpinRejoinsAsNewest() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("old", sourceApp: nil)
        store.addText("new", sourceApp: nil)
        guard let old = store.items.last else { return expect(false, "two rows recorded") }
        store.togglePinned(old)
        guard let pinned = store.items.first(where: { $0.text == "old" }) else {
            return expect(false, "the pin is resident")
        }
        expect(pinned.isPinned, "pinning stamped the row")
        store.togglePinned(pinned)
        guard let unpinned = store.items.first else { return expect(false, "history is not empty") }
        expect(unpinned.text == "old", "the unpinned row is now the newest entry")
        expect(!unpinned.isPinned, "the stamp is gone")
        expect(unpinned.createdAt > old.createdAt, "createdAt moved forward")
    }

    static func promoteLeavesAPinInPlace() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("pinned", sourceApp: nil)
        store.addText("loose", sourceApp: nil)
        store.addText("newest", sourceApp: nil)
        guard let toPin = store.items.first(where: { $0.text == "pinned" }) else {
            return expect(false, "three rows recorded")
        }
        store.togglePinned(toPin)
        guard let pin = store.items.first(where: { $0.text == "pinned" }),
            let loose = store.items.first(where: { $0.text == "loose" })
        else { return expect(false, "both rows resident") }
        store.promote(pin)
        expect(
            store.search("", filter: .all).first?.text == "pinned",
            "a promoted pin holds its place at the head of the Pinned block")
        store.promote(loose)
        let rows = store.search("", filter: .all)
        expect(rows.count == 3, "promote rewrote the row rather than adding one")
        expect(rows.dropFirst().first?.text == "loose", "the promoted row leads the history")
    }

    /// Retention and the resident window both exempt pins; a loose row of the same age goes.
    static func pinsSurvivePruneAndTheWindow() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("keep me", sourceApp: nil)
        store.addText("forget me", sourceApp: nil)
        guard let toPin = store.items.first(where: { $0.text == "keep me" }) else {
            return expect(false, "two rows recorded")
        }
        store.togglePinned(toPin)
        // A negative age puts the cutoff in the future, so every unpinned row is stale.
        store.maxAge = -1
        store.enforceLimits()
        expect(store.items.count == 1, "the loose row was pruned")
        expect(store.items.first?.text == "keep me", "the pin is exempt from retention")
        let reopened = ClipboardStore(directory: dir)
        reopened.load()
        expect(reopened.items.map(\.text) == ["keep me"], "the prune reached the database too")
    }

    /// A pin can live far outside the newest 1,000 rows; the two-branch load is what keeps it.
    static func pinsLeadFilteredSearch() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("needle in a haystack", sourceApp: nil)
        guard let ancient = store.items.first else { return expect(false, "one row recorded") }
        store.togglePinned(ancient)
        for index in 0..<1_100 { store.addText("filler \(index) needle", sourceApp: nil) }
        expect(store.items.count == 1_001, "the window holds 1,000 unpinned rows plus the pin")
        let rows = store.search("needle", filter: .all)
        expect(rows.first?.text == "needle in a haystack", "the pinned match leads the results")
        expect(rows.count { $0.text == "needle in a haystack" } == 1, "the pin is not duplicated")

        let reopened = ClipboardStore(directory: dir)
        reopened.load()
        let restored = reopened.search("needle", filter: .all)
        expect(
            restored.first?.text == "needle in a haystack",
            "the pin loads from beyond the window and still leads")
    }

    static func typeFilterSplitsHistory() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("just some prose", sourceApp: nil)
        store.addText("https://example.com", sourceApp: nil)
        store.addText("someone@example.com", sourceApp: nil)
        expect(store.search("", filter: .text).map(\.text) == ["just some prose"], "prose only")
        expect(store.search("", filter: .link).map(\.text) == ["https://example.com"], "links only")
        expect(
            store.search("", filter: .email).map(\.text) == ["someone@example.com"], "emails only")
        guard let link = store.items.first(where: { $0.text == "https://example.com" }) else {
            return expect(false, "the link is resident")
        }
        store.togglePinned(link)
        store.addText("https://later.example.com", sourceApp: nil)
        expect(
            store.search("", filter: .link).first?.text == "https://example.com",
            "the pin still leads its filtered block")
    }

    /// A query-only memo would hand the second call the first call's wider result.
    static func theMemoIncludesTheFilter() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("hello there", sourceApp: nil)
        store.addText("https://hello.example.com", sourceApp: nil)
        expect(store.search("hello", filter: .all).count == 2, "both rows match unfiltered")
        let links = store.search("hello", filter: .link)
        expect(links.map(\.text) == ["https://hello.example.com"], "the same query, a new filter")
        expect(store.search("hello", filter: .all).count == 2, "the wider result is still correct")
    }

    static func pinOrderIsRestoredFromDisk() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("alpha", sourceApp: nil)
        store.addText("beta", sourceApp: nil)
        store.addText("gamma", sourceApp: nil)
        guard let beta = store.items.first(where: { $0.text == "beta" }),
            let alpha = store.items.first(where: { $0.text == "alpha" })
        else { return expect(false, "three rows recorded") }
        store.togglePinned(beta)
        store.togglePinned(alpha)
        let before = store.search("", filter: .all).map(\.text)

        let reopened = ClipboardStore(directory: dir)
        reopened.load()
        expect(reopened.isAvailable, "the database reopened")
        expect(
            reopened.search("", filter: .all).map(\.text) == before, "pin order survived a reload")
    }

    static func clearAllEmptiesRowsAndFiles() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("text", sourceApp: nil)
        store.addImage(pngBytes(fill: 0x11), uti: "public.png", sourceApp: nil)
        guard let path = store.items.compactMap(\.imagePath).first else {
            return expect(false, "the image was stored")
        }
        store.clearAll()
        expect(store.items.isEmpty, "history is empty")
        expect(!FileManager.default.fileExists(atPath: path), "the image file is gone")
        var isDirectory: ObjCBool = false
        let imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        let exists = FileManager.default.fileExists(
            atPath: imagesDir.path, isDirectory: &isDirectory)
        expect(exists && isDirectory.boolValue, "the images directory is still there")
        let reopened = ClipboardStore(directory: dir)
        reopened.load()
        expect(reopened.items.isEmpty, "the rows are gone from the database too")
    }

    /// The inversion of Tinycast: a database that will not open is the user's history, not a cache.
    static func aDatabaseThatWillNotOpenIsKept() {
        let dir = scratch()
        defer { remove(dir) }
        let dbURL = dir.appendingPathComponent("clipboard.sqlite3")
        let garbage = Data("this is not a database, but it is somebody's history".utf8)
        expect((try? garbage.write(to: dbURL)) != nil, "the corrupt file was staged")
        let store = ClipboardStore(directory: dir)
        expect(!store.isAvailable, "the store reports itself unavailable")
        store.load()
        store.addText("would be lost", sourceApp: nil)
        expect(store.items.isEmpty, "nothing is recorded while the database is unavailable")
        expect(FileManager.default.fileExists(atPath: dbURL.path), "the file is still on disk")
        expect(
            (try? Data(contentsOf: dbURL)) == garbage,
            "and it was not silently recreated as an empty history")
    }

    /// `search_key` is a column, so a fold done at insert still matches after a reload.
    static func foldedSubstringSurvivesAReload() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("Café au lait", sourceApp: nil)
        expect(store.search("cafe", filter: .all).count == 1, "folded match in memory")

        let reopened = ClipboardStore(directory: dir)
        reopened.load()
        expect(reopened.search("CAFE", filter: .all).count == 1, "folded match after a reload")
        expect(reopened.items.first?.searchKey.contains("cafe") == true, "the key came from SQLite")
    }

    static func imagesAreFilesNotBlobs() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        let bytes = pngBytes(fill: 0xAB)
        store.addImage(bytes, uti: "public.png", sourceApp: nil)
        guard let stored = store.items.first, let path = stored.imagePath else {
            return expect(false, "the image was recorded")
        }
        expect(path.hasPrefix(dir.appendingPathComponent("images").path), "the file is ours")
        expect(FileManager.default.fileExists(atPath: path), "the bytes went to a file")
        expect(stored.imageUTI == "public.png", "the UTI is kept for paste-back")
        let dbURL = dir.appendingPathComponent("clipboard.sqlite3")
        let onDisk = (try? Data(contentsOf: dbURL)) ?? Data()
        expect(onDisk.range(of: bytes) == nil, "the database holds the path, not the blob")

        // The same picture copied twice re-recencies the row instead of writing a second file.
        store.addText("something else", sourceApp: nil)
        store.addImage(bytes, uti: "public.png", sourceApp: nil)
        expect(store.items.count == 2, "identical bytes promoted the existing row")
        expect(store.items.first?.imagePath == path, "and it is the same file, now at the head")

        // A pin is exempt from the image budget; the loose image goes and its file with it.
        store.addImage(pngBytes(fill: 0xCD), uti: "public.png", sourceApp: nil)
        guard let second = store.items.first, let secondPath = second.imagePath else {
            return expect(false, "the second image was recorded")
        }
        store.togglePinned(second)
        store.imageBudget = 1_000
        store.enforceLimits()
        expect(store.items.contains { $0.imagePath == secondPath }, "the pinned image is exempt")
        expect(FileManager.default.fileExists(atPath: secondPath), "and its file is still there")
        expect(!store.items.contains { $0.imagePath == path }, "the loose image row is gone")
        expect(waitForRemoval(of: path), "and the detached delete removed its file")

        // Only files inside our images directory are ours to delete.
        let outside = dir.appendingPathComponent("borrowed.png")
        expect((try? bytes.write(to: outside)) != nil, "an external file was staged")
        let foreign = ClipboardItem(
            kind: .image, imagePath: outside.path, imageUTI: "public.png")
        store.remove(foreign)
        expect(
            FileManager.default.fileExists(atPath: outside.path), "a path we do not own survives")
    }

    /// ⌘⌫ then ⌘Z: the same row comes back where its age puts it, image file and all; only when
    /// the undo window closes does the file go.
    static func aDeleteCanBeUndone() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addText("oldest", sourceApp: nil)
        store.addImage(pngBytes(fill: 0x11), uti: "public.png", sourceApp: nil)
        store.addText("newest", sourceApp: nil)
        guard store.items.count == 3, let picture = store.items.first(where: { $0.kind == .image }),
            let path = picture.imagePath
        else { return expect(false, "three rows recorded") }

        store.remove(picture, keepingBlob: true)
        expect(!store.items.contains { $0.id == picture.id }, "the row is gone from the list")
        expect(FileManager.default.fileExists(atPath: path), "but its file waits for an undo")

        expect(store.restore(picture)?.id == picture.id, "the undo brings back the same row")
        expect(store.items.map(\.text) == ["newest", nil, "oldest"], "it returns to its own place")
        store.restore(picture)
        expect(store.items.count == 3, "restoring twice does not duplicate it")
        let reopened = ClipboardStore(directory: dir)
        reopened.load()
        expect(
            reopened.items.map(\.id) == store.items.map(\.id),
            "and keeps its place after a relaunch, not jumping to the top")
        store.discardBlob(of: picture)
        expect(FileManager.default.fileExists(atPath: path), "a restored row keeps its file")

        store.remove(picture, keepingBlob: true)
        store.discardBlob(of: picture)
        expect(waitForRemoval(of: path), "once the undo window closes, the file goes")
    }

    /// A delete still waiting on its undo when the app quit leaves a file no row points at.
    static func anOrphanedImageIsSweptOnLoad() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        store.addImage(pngBytes(fill: 0x21), uti: "public.png", sourceApp: nil)
        store.addImage(pngBytes(fill: 0x22), uti: "public.png", sourceApp: nil)
        guard store.items.count == 2, let kept = store.items.first?.imagePath,
            let doomed = store.items.last
        else { return expect(false, "two images recorded") }
        store.remove(doomed, keepingBlob: true)
        let reopened = ClipboardStore(directory: dir)
        reopened.load()
        expect(!FileManager.default.fileExists(atPath: doomed.imagePath ?? ""), "the orphan is gone")
        expect(FileManager.default.fileExists(atPath: kept), "a referenced file stays")
    }

    /// Delete a picture, copy it again, then undo: one row and one file, not two of each.
    static func undoAfterTheSamePictureReturnsKeepsOneCopy() {
        let dir = scratch()
        defer { remove(dir) }
        let store = ClipboardStore(directory: dir)
        let bytes = pngBytes(fill: 0x33)
        store.addImage(bytes, uti: "public.png", sourceApp: nil)
        store.addText("after", sourceApp: nil)
        guard let original = store.items.first(where: { $0.kind == .image }),
            let oldPath = original.imagePath
        else { return expect(false, "the picture was recorded") }
        store.remove(original, keepingBlob: true)
        store.addImage(bytes, uti: "public.png", sourceApp: nil)
        guard let copy = store.items.first, copy.kind == .image else {
            return expect(false, "the re-copy was recorded")
        }
        let restored = store.restore(original)
        expect(restored?.id == copy.id, "the undo lands on the copy already there")
        expect(store.items.count { $0.kind == .image } == 1, "one picture in the list")
        expect(waitForRemoval(of: oldPath), "and the deleted one's file is gone")
        expect(FileManager.default.fileExists(atPath: copy.imagePath ?? ""), "the copy's file stays")
    }

    // MARK: - Helpers

    /// A throwaway directory per case, created here and removed by the case's `defer`.
    static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spare-clipboard-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A PNG signature and a run of filler: nothing here decodes an image, only stores bytes.
    static func pngBytes(fill: UInt8) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: fill, count: 4_096)
    }

    /// File deletes run on a detached task, so the assertion waits rather than racing it.
    static func waitForRemoval(of path: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return !FileManager.default.fileExists(atPath: path)
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
