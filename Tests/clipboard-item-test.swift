// Standalone test for the item model, compiling the real source rather than a copy.
import Foundation

@main
@MainActor
struct ClipboardItemTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        textFormClassification()
        overLongTextIsNeverWalked()
        imagesHaveNoTextForm()
        foldingIsLocaleIndependent()
        searchKeyIsCappedAtInsert()
        matchingUsesTheFoldedQuery()
        filterExclusivity()
        filterAllIsIdentity()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    static func textFormClassification() {
        let links = [
            "https://apple.com", "http://apple.com/path?q=1", "apple.com", "apple.com/store",
            "www.Apple.com", "vscode://file/tmp/x", "docs.google.com", "bit.ly/abc"
        ]
        for text in links {
            expect(form(text) == .link, "\(text) is a link")
        }

        let addresses = ["hi@apple.com", "mailto:hi@apple.com", "first.last@mail.example.co.uk"]
        for text in addresses {
            expect(form(text) == .email, "\(text) is an address")
        }

        let plain = [
            // Extensions that collide with a real TLD are the whole reason for the TLD set.
            "report.pdf", "index.html", "App.swift", "data.json", "Safari.app", "image.png",
            "hello world", "visit apple.com today", "3.14", "", "   ", "no-dot-at-all",
            "two@at@signs.com", "@apple.com", "hi@localhost", "line one\nline two"
        ]
        for text in plain {
            expect(form(text) == .plain, "\(text.debugDescription) is plain text")
        }
    }

    /// The detection limit exists so a multi-MB copy is never scanned for a scheme.
    static func overLongTextIsNeverWalked() {
        let long = "https://apple.com/" + String(repeating: "a", count: 4096)
        expect(form(long) == .plain, "an over-long token is prose, whatever it starts with")
        expect(
            form("https://apple.com/" + String(repeating: "a", count: 2000)) == .link,
            "a token inside the limit still classifies")
    }

    static func imagesHaveNoTextForm() {
        let image = ClipboardItem(kind: .image, imagePath: "/tmp/x.png", imageUTI: "public.png")
        expect(image.textForm == nil, "an image has no text form")
        expect(!image.isPinned, "an unpinned item reports no pin")
        expect(ClipboardFilter.image.matches(image), "the image filter takes it")
        expect(!ClipboardFilter.text.matches(image), "the text filter does not")
    }

    /// `locale: nil` is load-bearing: a Turkish fold maps `I` to `ı` and orphans every stored key.
    static func foldingIsLocaleIndependent() {
        let item = ClipboardItem(kind: .text, text: "Café")
        expect(item.matches(ClipboardItem.fold("cafe")), "a folded query finds an accented copy")
        expect(item.matches(ClipboardItem.fold("CAFÉ")), "case and diacritics both fold away")
        expect(ClipboardItem.fold("I") == "i", "capital I folds to ASCII i, never to a dotless ı")
        expect(!ClipboardItem.fold("I").contains("ı"), "no Turkish dotless i in a stored key")
        expect(ClipboardItem.fold("  hi  ") == "hi", "fold trims surrounding whitespace")
    }

    static func searchKeyIsCappedAtInsert() {
        let head = "Needle"
        let long = head + String(repeating: "x", count: ClipboardItem.searchKeyLimit * 2)
        let item = ClipboardItem(kind: .text, text: long)
        expect(
            item.searchKey.count <= ClipboardItem.searchKeyLimit,
            "the stored key stops at the limit")
        expect(item.matches("needle"), "a hit in the first few KB still matches")
        expect(!item.matches("needle!"), "and the key is a plain substring, not a pattern")
    }

    static func matchingUsesTheFoldedQuery() {
        let item = ClipboardItem(kind: .text, text: "Hello World")
        expect(item.matches(""), "an empty query matches everything")
        expect(ClipboardItem(kind: .image).matches(""), "including an image with no text")
        expect(item.matches("hello world"), "the caller folds once, the row does not re-fold")
        expect(!item.matches("Hello"), "an unfolded query is the caller's bug, not a match")
        expect(!item.matches("goodbye"), "a miss is a miss")
    }

    /// The five are exclusive: a copied URL is a link rather than a narrower kind of text.
    static func filterExclusivity() {
        let link = ClipboardItem(kind: .text, text: "https://apple.com")
        let mail = ClipboardItem(kind: .text, text: "hi@apple.com")
        let prose = ClipboardItem(kind: .text, text: "hello world")

        expect(ClipboardFilter.link.matches(link), "a URL is a link")
        expect(!ClipboardFilter.text.matches(link), "a URL is not filed under text")
        expect(ClipboardFilter.email.matches(mail), "an address is an email")
        expect(!ClipboardFilter.link.matches(mail), "an address is not a link")
        expect(ClipboardFilter.text.matches(prose), "prose is text")
        expect(!ClipboardFilter.image.matches(prose), "prose is not an image")

        let all = [link, mail, prose]
        expect(ClipboardFilter.link.apply(to: all) == [link], "link filter keeps only the URL")
        expect(
            ClipboardFilter.email.apply(to: all) == [mail], "email filter keeps only the address")
        expect(ClipboardFilter.text.apply(to: all) == [prose], "text filter keeps only the prose")
        expect(ClipboardFilter.image.apply(to: all).isEmpty, "no images in this history")
    }

    /// Identity for `all`, so an unfiltered list never pays for a copy.
    static func filterAllIsIdentity() {
        let items = [
            ClipboardItem(kind: .text, text: "https://apple.com"),
            ClipboardItem(kind: .image, imagePath: "/tmp/x.png")
        ]
        expect(ClipboardFilter.all.apply(to: items) == items, "all returns the same contents")
        expect(items.allSatisfy(ClipboardFilter.all.matches), "all matches every kind of row")
        expect(
            ClipboardFilter.allCases == [.all, .text, .image, .link, .email],
            "the menu order is the five exclusive cases")
    }

    // MARK: - Helpers

    static func form(_ text: String) -> ClipboardItem.TextForm? {
        ClipboardItem(kind: .text, text: text).textForm
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
