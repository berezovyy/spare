import Foundation

/// One captured entry. Search and type are derived from this, never from a SQLite column.
struct ClipboardItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case text, image }

    let id: UUID
    let kind: Kind
    let text: String?
    /// Folded once at insert, so a linear scan over history is cheap enough to replace FTS5.
    let searchKey: String
    /// Absolute path on disk; only files under the store's images dir are ours to delete.
    let imagePath: String?
    let imageUTI: String?
    /// Content hash, so the same picture copied twice does not land twice.
    let imageHash: String?
    let createdAt: Date
    /// Bundle ID of the app frontmost when the copy was captured.
    let sourceApp: String?
    /// When the entry was pinned; pins lead the list and are exempt from pruning.
    let pinnedAt: Date?

    var isPinned: Bool { pinnedAt != nil }

    /// A hit lives in the first few KB; folding a multi-MB copy in full buys nothing.
    static let searchKeyLimit = 4_096

    init(
        id: UUID = UUID(), kind: Kind, text: String? = nil, imagePath: String? = nil,
        imageUTI: String? = nil, imageHash: String? = nil, createdAt: Date = Date(),
        sourceApp: String? = nil, pinnedAt: Date? = nil, searchKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.searchKey = searchKey ?? Self.searchKey(for: text)
        self.imagePath = imagePath
        self.imageUTI = imageUTI
        self.imageHash = imageHash
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.pinnedAt = pinnedAt
    }

    /// Copy with the two fields the store rewrites; the pin is always stated outright.
    func with(createdAt: Date? = nil, pinnedAt: Date?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath, imageUTI: imageUTI,
            imageHash: imageHash, createdAt: createdAt ?? self.createdAt, sourceApp: sourceApp,
            pinnedAt: pinnedAt, searchKey: searchKey)
    }

    /// The key stored alongside the row: the head of the copy, folded once.
    static func searchKey(for text: String?) -> String {
        guard let text else { return "" }
        return fold(String(text.prefix(searchKeyLimit)))
    }

    /// `locale: nil` is load-bearing: a Turkish fold maps `I` to `ı` and orphans every stored key.
    static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The caller folds the query once, so a scan never re-folds a row. Every word has to hit,
    /// in any order, and a word may hit the content, the source app ("safari") or what the
    /// entry is ("link", "image") — so nobody has to learn a syntax to narrow the list.
    func matches(_ foldedQuery: String) -> Bool {
        guard !foldedQuery.isEmpty else { return true }
        // The common case — one word — never pays for the split.
        guard foldedQuery.contains(where: \.isWhitespace) else { return matchesWord(foldedQuery) }
        return foldedQuery.split(whereSeparator: \.isWhitespace).allSatisfy {
            matchesWord(Substring($0))
        }
    }

    private func matchesWord<S: StringProtocol>(_ word: S) -> Bool {
        if searchKey.contains(word) { return true }
        if let app = sourceAppName, app.contains(word) { return true }
        // Whole type words always count; a prefix needs four letters, so "add", "pin" or "pic"
        // typed as content do not drag in every address, pin or picture.
        return typeWords.contains { $0 == word || (word.count >= 4 && $0.hasPrefix(word)) }
    }

    /// The bundle id's last component, folded: `com.apple.Safari` → `safari`. Matching the whole
    /// id would let "apple" or "com" select half the history.
    private var sourceAppName: String? {
        sourceApp?.split(separator: ".").last.map { Self.fold(String($0)) }
    }

    /// What this entry *is*, in the words a person would type for it.
    private var typeWords: [String] {
        var words: [String] = isPinned ? ["pinned"] : []
        switch kind {
        case .image: words += ["image", "picture", "photo", "screenshot"]
        case .text:
            switch textForm {
            case .link: words += ["link", "url", "website"]
            case .email: words += ["email"]
            default: break
            }
        }
        return words
    }
}

/// The clipboard list's type filter. Exclusive: a copied URL is a link, not a kind of text.
enum ClipboardFilter: CaseIterable, Sendable {
    case all
    case text
    case image
    case link
    case email

    var title: String {
        switch self {
        case .all: return "All Types"
        case .text: return "Text Only"
        case .image: return "Images Only"
        case .link: return "Links Only"
        case .email: return "Emails Only"
        }
    }

    /// Also the header button's glyph, so it states the active filter without opening the menu.
    var systemImage: String {
        switch self {
        case .all: return "list.bullet"
        case .text: return "textformat"
        case .image: return "photo"
        case .link: return "link"
        case .email: return "at"
        }
    }

    /// What an empty list says, so a filter hiding every entry explains itself.
    var emptyMessage: String {
        switch self {
        case .all: return "Clipboard history is empty"
        case .text: return "No text in clipboard history"
        case .image: return "No images in clipboard history"
        case .link: return "No links in clipboard history"
        case .email: return "No email addresses in clipboard history"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .image: return item.kind == .image
        case .text: return item.textForm == .plain
        case .link: return item.textForm == .link
        case .email: return item.textForm == .email
        }
    }

    /// Identity for `all`, so an unfiltered list never pays for a copy.
    func apply(to items: [ClipboardItem]) -> [ClipboardItem] {
        self == .all ? items : items.filter(matches)
    }
}

extension ClipboardItem {
    /// What a text entry holds; `Kind` says how an entry is stored, this says what it is.
    enum TextForm: Sendable {
        case plain
        case link
        case email
    }

    /// Derived and never persisted, so reclassifying is a code change rather than a migration.
    var textForm: TextForm? {
        guard kind == .text, let text else { return nil }
        return Self.classify(text)
    }

    /// A link or an address is one short token, so anything longer is prose by definition.
    private static let detectionLimit = 2048

    /// A scheme-less link needs a TLD people actually copy, or every `report.pdf` reads as one.
    private static let commonTopLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "co", "ai", "app", "dev", "me", "info", "biz",
        "xyz", "tv", "ly", "gg", "to", "uk", "us", "eu", "de", "fr", "es", "it", "nl", "se", "no",
        "fi", "dk", "ch", "at", "be", "ie", "cz", "ru", "ua", "tr", "cn", "jp", "kr", "hk", "sg",
        "au", "nz", "ca", "mx", "br", "ar", "za"
    ]

    private static func classify(_ text: String) -> TextForm {
        // `utf8.count` is O(1); `count` would walk graphemes across a multi-MB copy.
        guard text.utf8.count <= detectionLimit else { return .plain }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return .plain }
        if let form = schemeForm(of: token) { return form }
        if isAddress(token) { return .email }
        return isBareDomain(token) ? .link : .plain
    }

    /// `mailto:` is an address; any other `scheme://` is a link, so `vscode://` needs no allowlist.
    private static func schemeForm(of token: String) -> TextForm? {
        if token.range(of: "mailto:", options: [.caseInsensitive, .anchored]) != nil {
            return .email
        }
        guard let separator = token.range(of: "://") else { return nil }
        let scheme = token[token.startIndex..<separator.lowerBound]
        guard !scheme.isEmpty,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "+" || $0 == "-" || $0 == ".") }
            )
        else { return nil }
        return .link
    }

    /// `local@domain.tld`: one `@`, a non-empty local part, and a host-shaped domain.
    private static func isAddress(_ token: String) -> Bool {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return topLevelLabel(of: parts[1]) != nil
    }

    /// A heuristic, and deliberately so: its worst case files a row under the wrong type.
    private static func isBareDomain(_ token: String) -> Bool {
        let host = token.prefix { !"/?#:".contains($0) }
        if host.range(of: "www.", options: [.caseInsensitive, .anchored]) != nil { return true }
        // Hosts are canonically lower case, which is what keeps `Safari.app` out of the links.
        guard !host.contains(where: \.isUppercase), let tld = topLevelLabel(of: host) else {
            return false
        }
        return commonTopLevelDomains.contains(String(tld))
    }

    /// The last label of a host, or nil unless every label is one — which is what rejects
    /// an address-shaped token like `@apple.com` before it can read as a bare domain.
    private static func topLevelLabel(of host: Substring) -> Substring? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isHostLabel), let tld = labels.last,
            tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        return tld
    }

    private static func isHostLabel(_ label: Substring) -> Bool {
        !label.isEmpty
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
