import CryptoKit
import Foundation
import SQLite3

// Spelled as the C macro in sqlite3.h, which isn't imported into Swift. Per file, so this one
// compiles standalone in its harness.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed clipboard history: rows in the database, image bytes in files beside it.
@MainActor
final class ClipboardStore {
    /// Newest-first with pins in place, every pin resident however old it is.
    private(set) var items: [ClipboardItem] = [] {
        didSet {
            searchCache = nil
            orderedCache = nil
            onChange?()
        }
    }

    /// One callback rather than observation, so this file stays free of any UI framework.
    var onChange: (() -> Void)?

    /// False when the database would not open. History is the product: the file is never deleted.
    private(set) var isAvailable = false

    /// Retention. The default matches the settings default; AppCore rewrites it on change.
    var maxAge: TimeInterval = 90 * 86_400

    /// Total bytes of stored images we keep. Oldest unpinned images go first when over.
    var imageBudget = 1_024 * 1_024 * 1_024

    /// How many unpinned rows stay resident; pins are extra and exempt.
    private static let memoryWindow = 1_000

    /// One-entry memo so repeated renders reuse the result; cleared by `items`' `didSet`.
    private var searchCache: (query: String, filter: ClipboardFilter, result: [ClipboardItem])?
    /// The same memo for the empty query, so the pinned split runs once per mutation.
    private var orderedCache: [ClipboardItem]?
    /// Where each delete awaiting its undo sat on disk.
    private var removedRowIDs: [ClipboardItem.ID: sqlite3_int64] = [:]

    private let dbURL: URL
    private let imagesDir: URL
    private var db: OpaquePointer?
    /// Keyed by the SQL itself and prepared eagerly at open, so a typo fails loudly at launch.
    private var statements: [String: OpaquePointer] = [:]

    /// No default: a harness must not be able to reach the real database by omission.
    init(directory: URL) {
        dbURL = directory.appendingPathComponent("clipboard.sqlite3")
        imagesDir = directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        isAvailable = openDatabase()
        // Never deleted, unlike Tinycast's: this database is the product, not a cache.
        if !isAvailable { closeDatabase() }
    }

    // Isolated so teardown may touch the main-actor pointers; the release is already on main.
    isolated deinit {
        closeDatabase()
    }

    // MARK: - Reading

    /// Called by AppCore inside a `Task`, never from `init`: opening is cheap, loading is not.
    func load() {
        guard let stmt = statements[Self.loadSQL] else { return }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_int64(stmt, 1, windowFloor())
        var loaded: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // A row that will not decode is skipped: one bad row must not empty the list.
            if let item = Self.row(stmt) { loaded.append(item) }
        }
        items = loaded
        // Age passes while the app isn't running; insert-time pruning alone can't catch that.
        enforceLimits()
        sweepOrphanedImages()
    }

    /// An image whose row is gone: a delete still waiting on its undo when the app quit or
    /// crashed. Nothing else would ever count or remove it.
    private func sweepOrphanedImages() {
        guard let stmt = statements[Self.imageRowsSQL] else { return }
        var referenced: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let path = Self.columnString(stmt, 1) { referenced.insert(path) }
        }
        sqlite3_reset(stmt)
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: imagesDir.path)) ?? [] {
            let path = imagesDir.appendingPathComponent(name).path
            if !referenced.contains(path) { try? manager.removeItem(atPath: path) }
        }
    }

    /// Called on load and whenever the retention or image-budget setting changes.
    func enforceLimits() {
        prune()
    }

    /// Display order for `query` under `filter`: pinned entries first, each block newest-first.
    func search(_ query: String, filter: ClipboardFilter) -> [ClipboardItem] {
        let folded = ClipboardItem.fold(query)
        // The filter joins the key: a query-only memo goes stale the moment the filter moves.
        if let searchCache, searchCache.query == folded, searchCache.filter == filter {
            return searchCache.result
        }
        // Filtering after the split leaves a matching pin in the Pinned section, in pin order.
        let result = filter.apply(to: unfiltered(folded))
        searchCache = (folded, filter, result)
        return result
    }

    /// Row index of `item` as currently listed, so the list can follow a row that moved.
    func rowIndex(of item: ClipboardItem, in query: String, filter: ClipboardFilter) -> Int? {
        search(query, filter: filter).firstIndex { $0.id == item.id }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imagePath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Writing

    func addText(_ text: String, sourceApp: String?) {
        if items.first?.kind == .text, items.first?.text == text { return }
        insert(ClipboardItem(kind: .text, text: text, sourceApp: sourceApp))
    }

    /// Stores the bytes as a file and only the path in the row; identical bytes re-recency
    /// the existing entry instead of writing a second copy of a 20 MB screenshot.
    func addImage(_ data: Data, uti: String?, sourceApp: String?) {
        guard isAvailable else { return }
        let hash = Self.hex(SHA256.hash(data: data))
        if let existing = itemByHash(hash) {
            promote(existing)
            return
        }
        let url = imagesDir.appendingPathComponent(UUID().uuidString + ".data")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        insert(
            ClipboardItem(
                kind: .image, imagePath: url.path, imageUTI: uti, imageHash: hash,
                sourceApp: sourceApp))
    }

    /// Move an item to the top; pasting or copying it from the list re-recencies it.
    func promote(_ item: ClipboardItem) {
        // A pinned row holds its place, so re-recencying it would rewrite for no change.
        guard !item.isPinned, items.first?.id != item.id else { return }
        reinsert(item.with(createdAt: Date(), pinnedAt: nil))
    }

    func togglePinned(_ item: ClipboardItem) {
        if item.isPinned { unpin(item) } else { pin(item) }
    }

    /// `keepingBlob` leaves an image's file on disk so the delete can still be undone; the caller
    /// then owes a `discardBlob(of:)` once the undo window closes.
    @discardableResult
    func remove(_ item: ClipboardItem, keepingBlob: Bool = false) -> Bool {
        // The rowid is the row's place in history on the next launch; an undo puts it back.
        if keepingBlob { removedRowIDs[item.id] = rowID(of: item) }
        guard perform(Self.deleteByIDSQL, { bindText($0, 1, item.id.uuidString) }) else {
            return false
        }
        items.removeAll { $0.id == item.id }
        if !keepingBlob { deleteBlob(item) }
        return true
    }

    /// Undo of a `remove(_:keepingBlob: true)`: the same row, back where its age puts it — now
    /// and after a relaunch, which orders by rowid. If a capture has taken the rowid since, the
    /// row comes back as newest on disk rather than not at all.
    ///
    /// Returns the row that now stands for it: itself, or — when the same picture was copied
    /// again in the meantime — that newer copy, so an undo never leaves the image twice.
    @discardableResult
    func restore(_ item: ClipboardItem) -> ClipboardItem? {
        guard isAvailable, !items.contains(where: { $0.id == item.id }) else { return nil }
        if let hash = item.imageHash, let copy = itemByHash(hash), copy.id != item.id {
            removedRowIDs[item.id] = nil
            if copy.imagePath != item.imagePath { deleteBlob(item) }
            return copy
        }
        let rowID = removedRowIDs.removeValue(forKey: item.id)
        guard (rowID.map { write(item, rowID: $0) } ?? false) || write(item) else { return nil }
        var next = items
        let index = next.firstIndex { $0.createdAt < item.createdAt } ?? next.count
        next.insert(item, at: index)
        items = next
        return item
    }

    /// The end of an undo window: the deleted image's bytes go for good.
    func discardBlob(of item: ClipboardItem) {
        removedRowIDs[item.id] = nil
        guard !items.contains(where: { $0.id == item.id }) else { return }
        deleteBlob(item)
    }

    /// Enumerates and deletes the images directory's contents: removing the directory itself
    /// fails silently while a Finder window holds it.
    func clearAll() {
        guard isAvailable, sqlite3_exec(db, "DELETE FROM items", nil, nil, nil) == SQLITE_OK else {
            return
        }
        let manager = FileManager.default
        // Names, not URLs: an enumerated URL can come back with a resolved base, which `owns`
        // would then read as a path outside our own directory.
        for name in (try? manager.contentsOfDirectory(atPath: imagesDir.path)) ?? [] {
            try? manager.removeItem(at: imagesDir.appendingPathComponent(name))
        }
        items = []
    }

    // MARK: - Ordering

    private func unfiltered(_ folded: String) -> [ClipboardItem] {
        guard !folded.isEmpty else { return orderedItems }
        // Pins are matched separately: all resident, and matching them first is what leads them.
        return pinnedItems.filter { $0.matches(folded) }
            + items.filter { !$0.isPinned && $0.matches(folded) }
    }

    private var orderedItems: [ClipboardItem] {
        if let orderedCache { return orderedCache }
        let pinned = pinnedItems
        // An unpinned history renders `items` as-is, so it never pays for the split.
        let result = pinned.isEmpty ? items : pinned + items.filter { !$0.isPinned }
        orderedCache = result
        return result
    }

    /// The Pinned section in pin order, so a new pin joins the end rather than the head.
    private var pinnedItems: [ClipboardItem] {
        items.filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantFuture) < ($1.pinnedAt ?? .distantFuture) }
    }

    // MARK: - Pins

    /// The row keeps its place and gains a stamp, which files it at the end of the Pinned block.
    private func pin(_ item: ClipboardItem) {
        let stamp = Date()
        let pinned = item.with(pinnedAt: stamp)
        let stamped = perform(
            Self.pinSQL,
            { stmt in
                sqlite3_bind_double(stmt, 1, stamp.timeIntervalSince1970)
                self.bindText(stmt, 2, item.id.uuidString)
            })
        guard stamped else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = pinned
        } else {
            // Pinned from outside the resident window, so splice it in by recency.
            let index = items.firstIndex { $0.createdAt < pinned.createdAt } ?? items.count
            items.insert(pinned, at: index)
        }
    }

    /// Unpinning rejoins the history as the newest entry rather than at its original age.
    private func unpin(_ item: ClipboardItem) {
        reinsert(item.with(createdAt: Date(), pinnedAt: nil))
    }

    // MARK: - Row writes

    private func insert(_ item: ClipboardItem) {
        guard write(item) else { return }
        items.insert(item, at: 0)
        trimWindow()
        prune()
    }

    /// Rewrite a row under the same id so it leads the history again.
    private func reinsert(_ updated: ClipboardItem) {
        guard isAvailable else { return }
        // One transaction: `id` is UNIQUE, and a crash between the two must not lose the row.
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        let deleted = perform(Self.deleteByIDSQL) { self.bindText($0, 1, updated.id.uuidString) }
        guard deleted, write(updated) else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        // Array ops also cover an item surfaced from beyond the resident window. Built aside and
        // assigned once: each assignment fires `onChange`, and an open list re-rendering between
        // the remove and the insert would lose the row it was keeping the selection on.
        var next = items
        next.removeAll { $0.id == updated.id }
        next.insert(updated, at: 0)
        items = next
        trimWindow()
    }

    private func rowID(of item: ClipboardItem) -> sqlite3_int64? {
        guard let stmt = statements[Self.rowIDSQL] else { return nil }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        bindText(stmt, 1, item.id.uuidString)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func write(_ item: ClipboardItem, rowID: sqlite3_int64? = nil) -> Bool {
        perform(rowID == nil ? Self.insertSQL : Self.insertAtSQL) { stmt in
            if let rowID { sqlite3_bind_int64(stmt, 11, rowID) }
            self.bindText(stmt, 1, item.id.uuidString)
            self.bindText(stmt, 2, item.kind.rawValue)
            self.bindText(stmt, 3, item.text)
            self.bindText(stmt, 4, item.searchKey)
            self.bindText(stmt, 5, item.imagePath)
            self.bindText(stmt, 6, item.imageUTI)
            self.bindText(stmt, 7, item.imageHash)
            sqlite3_bind_double(stmt, 8, item.createdAt.timeIntervalSince1970)
            self.bindText(stmt, 9, item.sourceApp)
            if let pinnedAt = item.pinnedAt {
                sqlite3_bind_double(stmt, 10, pinnedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
        }
    }

    /// Cap the resident window, but never drop a pinned row: those render however old they are.
    private func trimWindow() {
        let unpinned = items.count { !$0.isPinned }
        guard unpinned > Self.memoryWindow, let index = items.lastIndex(where: { !$0.isPinned })
        else { return }
        items.remove(at: index)
    }

    private func itemByHash(_ hash: String) -> ClipboardItem? {
        guard let stmt = statements[Self.byHashSQL] else { return nil }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        bindText(stmt, 1, hash)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.row(stmt)
    }

    // MARK: - Retention

    private func prune() {
        guard isAvailable else { return }
        var strandedPaths = pruneByAge()
        strandedPaths += pruneByImageBudget()
        // A retention cut can strand hundreds of files, so delete them off the main actor.
        if !strandedPaths.isEmpty {
            Task.detached(priority: .utility) {
                for path in strandedPaths { try? FileManager.default.removeItem(atPath: path) }
            }
        }
    }

    /// Drops every unpinned row older than `maxAge`, returning the image files it stranded.
    private func pruneByAge() -> [String] {
        guard maxAge < .greatestFiniteMagnitude else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        var stranded: [String] = []
        if let stmt = statements[Self.staleImagesSQL] {
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                // Only files we own; an external reference just loses its row.
                if let path = Self.columnString(stmt, 0), owns(path) { stranded.append(path) }
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        let dropped = perform(
            Self.deleteStaleSQL, { sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970) })
        guard dropped else { return [] }
        // Against the oldest unpinned row: an exempt pin would make this permanently true.
        if items.last(where: { !$0.isPinned }).map({ $0.createdAt < cutoff }) == true {
            items.removeAll { $0.createdAt < cutoff && !$0.isPinned }
        }
        return stranded
    }

    /// Drops the oldest unpinned images until the stored bytes fit the budget; pins are exempt.
    private func pruneByImageBudget() -> [String] {
        guard let stmt = statements[Self.imageRowsSQL] else { return [] }
        var rows: [(id: String, path: String, pinned: Bool, size: Int)] = []
        var total = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = Self.columnString(stmt, 0), let path = Self.columnString(stmt, 1)
            else { continue }
            let pinned = sqlite3_column_type(stmt, 2) != SQLITE_NULL
            let size = Self.fileSize(path)
            total += size
            rows.append((id, path, pinned, size))
        }
        sqlite3_reset(stmt)
        guard total > imageBudget else { return [] }
        var stranded: [String] = []
        var droppedIDs: Set<String> = []
        // Oldest first, pins skipped: they render however old they are.
        for row in rows where !row.pinned {
            guard total > imageBudget else { break }
            guard perform(Self.deleteByIDSQL, { self.bindText($0, 1, row.id) }) else { break }
            total -= row.size
            droppedIDs.insert(row.id)
            if owns(row.path) { stranded.append(row.path) }
        }
        if !droppedIDs.isEmpty {
            items.removeAll { droppedIDs.contains($0.id.uuidString) }
        }
        return stranded
    }

    private func deleteBlob(_ item: ClipboardItem) {
        guard let path = item.imagePath, owns(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Whether a path is inside our images directory; only those are ours to delete.
    private func owns(_ path: String) -> Bool {
        path.hasPrefix(imagesDir.path + "/")
    }

    private static func fileSize(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SQLite

    private static let schema = """
        CREATE TABLE IF NOT EXISTS items(
          id          TEXT NOT NULL UNIQUE,
          kind        TEXT NOT NULL,
          text        TEXT,
          search_key  TEXT,
          image_path  TEXT,
          image_uti   TEXT,
          image_hash  TEXT,
          created_at  REAL NOT NULL,
          source_app  TEXT,
          pinned_at   REAL
        );
        CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
        CREATE INDEX IF NOT EXISTS items_pinned_at ON items(pinned_at) WHERE pinned_at IS NOT NULL;
        CREATE INDEX IF NOT EXISTS items_image_hash
          ON items(image_hash) WHERE image_hash IS NOT NULL;
        PRAGMA user_version = 1;
        """

    private static let columns =
        "id, kind, text, search_key, image_path, image_uti, image_hash, created_at, "
        + "source_app, pinned_at"

    private static let insertSQL = "INSERT INTO items(\(columns)) VALUES(?,?,?,?,?,?,?,?,?,?)"
    private static let insertAtSQL =
        "INSERT INTO items(\(columns), rowid) VALUES(?,?,?,?,?,?,?,?,?,?,?)"
    private static let rowIDSQL = "SELECT rowid FROM items WHERE id = ?"

    /// Two indexed branches, deliberately not one `OR`: a pin can live far outside the window.
    private static let loadSQL = """
        SELECT \(columns) FROM (
          SELECT rowid AS rid, * FROM items WHERE rowid >= ?1
          UNION ALL
          SELECT rowid AS rid, * FROM items WHERE pinned_at IS NOT NULL AND rowid < ?1
        ) ORDER BY rid DESC
        """

    private static let windowFloorSQL =
        "SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC LIMIT 1 OFFSET ?"

    private static let deleteByIDSQL = "DELETE FROM items WHERE id = ?"

    /// Only ever sets a stamp: unpinning rewrites the whole row so it leads the history again.
    private static let pinSQL = "UPDATE items SET pinned_at = ? WHERE id = ?"

    private static let staleImagesSQL = """
        SELECT image_path FROM items
        WHERE created_at < ? AND pinned_at IS NULL AND image_path IS NOT NULL
        """

    private static let deleteStaleSQL =
        "DELETE FROM items WHERE created_at < ? AND pinned_at IS NULL"

    private static let byHashSQL = """
        SELECT \(columns) FROM items WHERE image_hash = ? ORDER BY rowid DESC LIMIT 1
        """

    private static let imageRowsSQL = """
        SELECT id, image_path, pinned_at FROM items
        WHERE image_path IS NOT NULL ORDER BY created_at ASC
        """

    private static let allStatements = [
        insertSQL, loadSQL, windowFloorSQL, deleteByIDSQL, pinSQL, staleImagesSQL, deleteStaleSQL,
        byHashSQL, imageRowsSQL, insertAtSQL, rowIDSQL
    ]

    private func openDatabase() -> Bool {
        guard
            sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK
        else { return false }
        sqlite3_busy_timeout(db, 2_000)
        guard
            sqlite3_exec(
                db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-256;",
                nil, nil, nil) == SQLITE_OK,
            sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK
        else { return false }
        // Eagerly, never lazily: a SQL typo then fails at launch rather than in one rare branch.
        for sql in Self.allStatements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return false
            }
            statements[sql] = stmt
        }
        return true
    }

    private func closeDatabase() {
        for stmt in statements.values { sqlite3_finalize(stmt) }
        statements = [:]
        // v2 defers the close while statements are live rather than returning SQLITE_BUSY.
        sqlite3_close_v2(db)
        db = nil
    }

    /// Bind, step to completion, then reset **and** clear bindings: bindings survive a reset,
    /// so a later call binding fewer parameters would silently reuse the last row's.
    private func perform(_ sql: String, _ bind: (OpaquePointer) -> Void) -> Bool {
        guard let stmt = statements[sql] else { return false }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// `SQLITE_STATIC` would tell SQLite it may read a Swift buffer later: use-after-free.
    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// The floor rowid `loadSQL` reads from; 0 means no floor, so load everything.
    private func windowFloor() -> sqlite3_int64 {
        guard let stmt = statements[Self.windowFloorSQL] else { return 0 }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_int(stmt, 1, Int32(Self.memoryWindow - 1))
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    private static func row(_ stmt: OpaquePointer?) -> ClipboardItem? {
        guard let idString = columnString(stmt, 0), let id = UUID(uuidString: idString),
            let kindString = columnString(stmt, 1),
            let kind = ClipboardItem.Kind(rawValue: kindString)
        else { return nil }
        return ClipboardItem(
            id: id, kind: kind, text: columnString(stmt, 2), imagePath: columnString(stmt, 4),
            imageUTI: columnString(stmt, 5), imageHash: columnString(stmt, 6),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            sourceApp: columnString(stmt, 8), pinnedAt: columnDate(stmt, 9),
            searchKey: columnString(stmt, 3))
    }

    /// `column_double` on NULL returns 0.0, which is a valid date in 1970.
    private static func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    /// `column_text` → `column_bytes` → `String(decoding:)`, in that order: the text accessor
    /// may convert the value and invalidate a length read before it.
    private static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
}
