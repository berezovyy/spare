import AppKit
import ImageIO

/// Downsampled, memory-capped image loading: ImageIO decodes to exactly the size needed, so a
/// 20 MP screenshot costs a ~65 KB thumbnail instead of an 80 MB bitmap.
enum ImageThumbnail {
    /// `NSCache` is thread-safe but not `Sendable`, so assert the guarantee once here. The
    /// generation counter rides along because it must be read and compared under the same lock.
    private final class ImageCache: NSCache<NSString, NSImage>, @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0

        /// Stamp a decode with this before it starts; a purge invalidates every stamp it predates.
        var currentGeneration: Int {
            lock.lock()
            defer { lock.unlock() }
            return generation
        }

        /// Drops the bitmaps *and* disowns every decode already in flight.
        func purge() {
            lock.lock()
            generation += 1
            lock.unlock()
            removeAllObjects()
        }

        /// Ignores a decode that started before the last purge, so a late arrival cannot
        /// re-insert into a cache the panel already emptied and strand memory above baseline.
        func store(_ image: NSImage, forKey key: NSString, cost: Int, generation stamp: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard stamp == generation else { return }
            setObject(image, forKey: key, cost: cost)
        }
    }

    /// Row thumbnails, byte-bounded and kept warm, so re-opening draws instantly.
    private static let rowCache: ImageCache = {
        let cache = ImageCache()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Large previews, byte-bounded and purged on close, so browsing memory stays flat.
    private static let previewCache: ImageCache = {
        let cache = ImageCache()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Longest-edge size at or below which a decode is a "row" thumbnail; larger is a "preview".
    private static let rowThreshold: CGFloat = 128

    /// The two tiers differ by lifetime, not by size: rows are kept, previews are dropped.
    private static func pick(_ maxPixel: CGFloat) -> ImageCache {
        maxPixel <= rowThreshold ? rowCache : previewCache
    }

    private static func cacheKey(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixel))" as NSString
    }

    /// Frees the preview bitmaps on dismiss; row thumbnails stay warm for a re-open.
    static func purgePreviews() {
        previewCache.purge()
    }

    /// Cache-only, never touching disk, so a warm thumbnail renders on the same frame.
    static func cached(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        pick(maxPixel).object(forKey: cacheKey(url, maxPixel))
    }

    /// A freshly-decoded, thereafter-immutable `NSImage` is safe to move across the actor boundary.
    private struct Decoded: @unchecked Sendable { let image: NSImage? }

    /// Returns the decode directly, so an eviction mid-decode can't strand a placeholder. The
    /// generation is read here, before the hop: a purge during the decode then discards it.
    static func loadAsync(_ url: URL, maxPixel: CGFloat) async -> NSImage? {
        if let cached = cached(url, maxPixel: maxPixel) { return cached }
        let stamp = pick(maxPixel).currentGeneration
        return await Task.detached(priority: .userInitiated) {
            Decoded(image: decode(url, maxPixel: maxPixel, generation: stamp))
        }.value.image
    }

    /// A thumbnail capped at `maxPixel`, cached per path and size; decodes synchronously.
    static func load(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        decode(url, maxPixel: maxPixel, generation: pick(maxPixel).currentGeneration)
    }

    /// Pixel dimensions read from image metadata — no full decode.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Decoding

    private static func decode(_ url: URL, maxPixel: CGFloat, generation: Int) -> NSImage? {
        let cache = pick(maxPixel)
        let key = cacheKey(url, maxPixel)
        if let cached = cache.object(forKey: key) { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Without this ImageIO defers the pixel decode to the first draw, on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        // Cost = the decoded bitmap's real byte footprint, so `totalCostLimit` bounds actual RAM.
        cache.store(
            image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height, generation: generation)
        return image
    }
}
