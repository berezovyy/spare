// Standalone test for the write half of the paste path. We are the clipboard app: a harness that
// wrote the shared pasteboard would land in a running Spare Dev's history, so every case here
// uses `NSPasteboard.withUniqueName()` and a throwaway store directory. The production pasteboard
// is not named anywhere in this file, and the ⌘V half is e2e (phase 46).
import AppKit

@main
@MainActor
struct PasterTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        textIsWrittenWithTheInternalMarker()
        writingTextPromotesTheItem()
        imageDeclaresTheStoredUTI()
        aVanishedImageWritesNothing()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    static func textIsWrittenWithTheInternalMarker() {
        withScratchStore { store in
            let pb = NSPasteboard.withUniqueName()
            let nonce = "spare paster nonce \(UUID().uuidString)"
            store.addText(nonce, sourceApp: nil)
            guard let item = store.items.first else {
                expect(false, "the store recorded the text")
                return
            }

            expect(Paster.write(item, store: store, to: pb), "writing a text item succeeds")
            expect(pb.string(forType: .string) == nonce, "the pasteboard carries the text")
            expect(
                pb.types?.map(\.rawValue).contains(CapturePolicy.internalType) == true,
                "the write is marked internal, so the monitor skips it")
        }
    }

    /// Without the promote a paste would leave the item where it was and the list would not move.
    static func writingTextPromotesTheItem() {
        withScratchStore { store in
            let pb = NSPasteboard.withUniqueName()
            store.addText("older", sourceApp: nil)
            store.addText("newer", sourceApp: nil)
            guard let older = store.items.last else {
                expect(false, "the store recorded both entries")
                return
            }

            expect(Paster.write(older, store: store, to: pb), "writing the older item succeeds")
            expect(store.items.first?.id == older.id, "the written item leads history")
        }
    }

    /// The stored UTI, not `.png`: the bytes on disk are whatever the source app offered.
    static func imageDeclaresTheStoredUTI() {
        withScratchStore { store in
            let pb = NSPasteboard.withUniqueName()
            let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
            store.addImage(bytes, uti: "public.jpeg", sourceApp: nil)
            guard let item = store.items.first, item.kind == .image else {
                expect(false, "the store recorded the image")
                return
            }

            expect(Paster.write(item, store: store, to: pb), "writing an image item succeeds")
            let types = pb.types?.map(\.rawValue) ?? []
            expect(types.contains("public.jpeg"), "the declared type is the stored image_uti")
            expect(!types.contains("public.png"), "no PNG is declared for a JPEG payload")
            expect(
                pb.data(forType: .init("public.jpeg")) == bytes, "the stored bytes are the payload")
            expect(types.contains(CapturePolicy.internalType), "the image write is marked too")
        }
    }

    static func aVanishedImageWritesNothing() {
        withScratchStore { store in
            let pb = NSPasteboard.withUniqueName()
            let before = pb.changeCount
            store.addImage(Data([0x89, 0x50, 0x4E, 0x47]), uti: "public.png", sourceApp: nil)
            guard let item = store.items.first, let url = store.imageURL(for: item) else {
                expect(false, "the store recorded the image")
                return
            }
            try? FileManager.default.removeItem(at: url)

            expect(!Paster.write(item, store: store, to: pb), "a missing blob reports failure")
            expect(pb.changeCount == before, "and leaves the pasteboard untouched")
        }
    }

    // MARK: - Helpers

    /// A store directory per run, torn down after: `ClipboardStore` has no default directory
    /// precisely so a harness cannot reach the installed app's history by omission.
    static func withScratchStore(_ body: (ClipboardStore) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spare-paster-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        guard store.isAvailable else {
            expect(false, "the scratch store opened at \(directory.path)")
            return
        }
        body(store)
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
