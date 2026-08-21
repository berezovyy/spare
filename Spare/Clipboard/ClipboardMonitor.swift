import AppKit
import ImageIO

/// Polls `NSPasteboard.general`, because macOS has no change notification. Owns no policy:
/// every decision about a copy comes back from `CapturePolicy`, read from the root type set.
@MainActor
final class ClipboardMonitor {
    /// Attached by `Paster` when *we* write, so a paste-back never re-enters history.
    static let internalType = NSPasteboard.PasteboardType(CapturePolicy.internalType)

    /// 500 ms is a correctness floor, not a battery tuning knob: Clipy raced its own poll for
    /// six years reading faster than a writing app finishes filling the pasteboard.
    private static let pollInterval: TimeInterval = 0.5

    private let store: ClipboardStore
    private let settings: Settings
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var sessionTokens: [NotificationToken] = []
    private var lastChangeCount = 0

    init(store: ClipboardStore, settings: Settings, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.settings = settings
        self.pasteboard = pasteboard
    }

    // Isolated so teardown may touch the main-actor timer; the poll block is already weak.
    isolated deinit {
        timer?.invalidate()
    }

    func start() {
        installSessionObservers()
        startPolling()
    }

    func stop() {
        stopPolling()
    }

    /// Adopt the current change count without reading it, for a write we know is ours.
    func rebaseline() {
        lastChangeCount = pasteboard.changeCount
    }

    // Fast user switching: another session's clipboard is not ours, so stop waking for it.
    private func installSessionObservers() {
        guard sessionTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sessionTokens = [
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // `queue: .main` is the guarantee; this states it rather than hops.
                    MainActor.assumeIsolated { self?.stopPolling() }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startPolling() }
                }, center: center)
        ]
    }

    // Re-baselining first is what stops a clip made in another session reading as new on resume.
    private func startPolling() {
        guard timer == nil else { return }
        rebaseline()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // The timer is added to `RunLoop.main` below, so delivery on the main thread is
            // contractual. This and HotKeyCenter's C callback are the only `assumeIsolated`.
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        // `.common` so a menu tracking loop or a live resize does not stall capture.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // The root type set, read before any content: `types` advertises types the item does
        // not carry, so every decision has to be made from this list rather than from a read.
        let types = (pasteboard.types ?? []).map(\.rawValue)
        // Our own paste, and every marker a password manager or the OS puts on a secret copy.
        guard !CapturePolicy.isSkipped(types: types) else { return }

        // The pasteboard carries no source, so attribute the copy to the frontmost app.
        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let sourceApp, settings.ignoredApps.contains(sourceApp) { return }

        let text = pasteboard.string(forType: .string)
        // Only an image needs its bytes measured, and only once the text branch is out.
        let image = text == nil ? imagePayload(in: types) : nil
        switch CapturePolicy.decide(types: types, text: text, imageByteCount: image?.data.count) {
        case .skip:
            return
        case .text(let text):
            store.addText(text, sourceApp: sourceApp)
        case .image(let uti, let needsTranscode):
            guard settings.capturesImages, let image else { return }
            record(image.data, uti: uti, needsTranscode: needsTranscode, sourceApp: sourceApp)
        }
    }

    /// The best offered image type and its bytes, in `CapturePolicy`'s order.
    private func imagePayload(in types: [String]) -> (uti: String, data: Data)? {
        guard let uti = CapturePolicy.imageType(in: types),
            let data = pasteboard.data(forType: NSPasteboard.PasteboardType(uti))
        else { return nil }
        return (uti, data)
    }

    /// The file write goes off-main and returns bytes; the row insert comes back to this actor.
    private func record(_ data: Data, uti: String, needsTranscode: Bool, sourceApp: String?) {
        guard needsTranscode else {
            store.addImage(data, uti: uti, sourceApp: sourceApp)
            return
        }
        let store = store
        // A big TIFF re-encode costs 100 ms+, which is longer than the poll interval.
        Task.detached(priority: .utility) {
            guard let png = Self.transcodeToPNG(data) else { return }
            await store.addImage(png, uti: "public.png", sourceApp: sourceApp)
        }
    }

    /// ImageIO, never `NSBitmapImageRep`: the latter decodes the whole TIFF into an AppKit
    /// bitmap that the autorelease pool holds until the next main-thread turn.
    private nonisolated static func transcodeToPNG(_ data: Data) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output as CFMutableData, "public.png" as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
    }
}
