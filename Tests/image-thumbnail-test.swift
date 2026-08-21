// Standalone test for the thumbnail cache: real PNGs in a temp directory, no pasteboard.
// The case that matters is the generation guard — Tinycast's version re-inserted a decode that
// landed after the purge, so idle memory never came back down.
import AppKit
import ImageIO

@main
@MainActor
struct ImageThumbnailTests {
    static var failures = 0
    static var passes = 0

    private static let rowPixel: CGFloat = 64
    private static let previewPixel: CGFloat = 900

    static func main() async {
        decodeIsDownsampledToTheRequestedSize()
        warmRowThumbnailIsServedFromCache()
        purgeDropsPreviewsAndKeepsRows()
        await purgeDisownsADecodeAlreadyInFlight()
        costIsTheBitmapFootprint()
        pixelSizeReadsMetadata()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    /// ImageIO decodes *to* the target: the point of the file is that big images never inflate.
    static func decodeIsDownsampledToTheRequestedSize() {
        withPNG(pixels: 512) { url in
            guard let image = ImageThumbnail.load(url, maxPixel: rowPixel) else {
                expect(false, "a 512 px PNG decodes at 64 px")
                return
            }
            expect(image.size.width <= rowPixel, "width is capped at the requested size")
            expect(image.size.height <= rowPixel, "height is capped at the requested size")
            expect(image.size.width > 0, "the thumbnail is not empty")
        }
    }

    static func warmRowThumbnailIsServedFromCache() {
        withPNG(pixels: 256) { url in
            expect(
                ImageThumbnail.cached(url, maxPixel: rowPixel) == nil,
                "a never-decoded path is a cache miss")
            _ = ImageThumbnail.load(url, maxPixel: rowPixel)
            expect(
                ImageThumbnail.cached(url, maxPixel: rowPixel) != nil,
                "the decode left a warm entry behind")
        }
    }

    /// The two tiers differ by lifetime: a dismissal frees previews and keeps rows warm.
    static func purgeDropsPreviewsAndKeepsRows() {
        withPNG(pixels: 1024) { url in
            _ = ImageThumbnail.load(url, maxPixel: rowPixel)
            _ = ImageThumbnail.load(url, maxPixel: previewPixel)
            expect(
                ImageThumbnail.cached(url, maxPixel: previewPixel) != nil,
                "the preview is cached before the purge")

            ImageThumbnail.purgePreviews()

            expect(
                ImageThumbnail.cached(url, maxPixel: previewPixel) == nil,
                "purgePreviews frees the preview bitmaps")
            expect(
                ImageThumbnail.cached(url, maxPixel: rowPixel) != nil,
                "purgePreviews leaves the row thumbnails warm")
        }
    }

    /// The fix. The load reads its generation before the hop, so a purge in between discards it
    /// however the two race: either the store is refused, or the purge removed it anyway.
    static func purgeDisownsADecodeAlreadyInFlight() async {
        await withPNG(pixels: 1600) { url in
            ImageThumbnail.purgePreviews()
            let task = Task.detached(priority: .userInitiated) {
                await ImageThumbnail.loadAsync(url, maxPixel: previewPixel)
            }
            // Long enough for the detached task to have taken its generation stamp.
            try? await Task.sleep(for: .milliseconds(50))
            ImageThumbnail.purgePreviews()

            let decoded = await task.value
            expect(decoded != nil, "the caller still gets its image back")
            expect(
                ImageThumbnail.cached(url, maxPixel: previewPixel) == nil,
                "the in-flight decode did not re-enter the purged cache")
        }
    }

    /// `NSCache` does not expose a stored cost, so this locks the number that is handed to it:
    /// the decoded bitmap's real footprint, which is what makes `totalCostLimit` mean bytes.
    static func costIsTheBitmapFootprint() {
        withPNG(pixels: 512) { url in
            guard let image = ImageThumbnail.load(url, maxPixel: rowPixel),
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                expect(false, "the thumbnail carries a CGImage")
                return
            }
            let cost = cgImage.bytesPerRow * cgImage.height
            expect(cost > 1, "cost is a byte count, not a per-object 1")
            expect(
                cost >= cgImage.width * cgImage.height,
                "cost covers at least one byte per pixel")
            expect(cost < 8 * 1024 * 1024, "a 64 px thumbnail fits well inside the row budget")
        }
    }

    static func pixelSizeReadsMetadata() {
        withPNG(pixels: 300) { url in
            let size = ImageThumbnail.pixelSize(of: url)
            expect(size == CGSize(width: 300, height: 300), "pixelSize reports the source size")
        }
    }

    // MARK: - Helpers

    /// A distinct path per call, so one case's warm cache never answers another's miss.
    static func withPNG(pixels: Int, _ body: (URL) -> Void) {
        guard let url = makePNG(pixels: pixels) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        body(url)
    }

    static func withPNG(pixels: Int, _ body: (URL) async -> Void) async {
        guard let url = makePNG(pixels: pixels) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        await body(url)
    }

    static func makePNG(pixels: Int) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spare-thumbnail-\(UUID().uuidString).png")
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            expect(false, "could not allocate a \(pixels) px bitmap")
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            expect(false, "could not encode a PNG")
            return nil
        }
        do {
            try data.write(to: url)
        } catch {
            expect(false, "could not write \(url.lastPathComponent): \(error)")
            return nil
        }
        return url
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
