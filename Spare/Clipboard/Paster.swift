import AppKit
import Carbon.HIToolbox

/// Puts an item back on the pasteboard and synthesizes ⌘V. Every write carries
/// `CapturePolicy.internalType`, which is the one thing keeping a paste out of history:
/// if the writer and the monitor ever disagree on that marker, Spare re-captures itself.
enum Paster {
    /// Covers the gap between `activate()` returning and the target accepting a keystroke.
    private static let activationDelay: TimeInterval = 0.08

    /// Shorter: nothing to activate, only the pasteboard write reaching the target's process.
    private static let directPostDelay: TimeInterval = 0.05

    /// Write the item, activate `app`, and paste there. False when the item is already gone.
    @MainActor @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, into app: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
        return true
    }

    /// Paste into `app` without activating it, so a panel on top keeps its focus.
    @MainActor @discardableResult
    static func pasteInPlace(
        _ item: ClipboardItem, store: ClipboardStore, into app: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        guard let pid = app?.processIdentifier else { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
            postCommandV(toPid: pid)
        }
        return true
    }

    /// Put the item on the pasteboard without pasting; the marker still stops re-capture.
    @MainActor @discardableResult
    static func copy(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        write(item, store: store)
    }

    /// The seam every case above shares, and the only one a harness may call: `pb` is a
    /// parameter so a test can pass `NSPasteboard.withUniqueName()` and leave `.general` alone.
    @MainActor @discardableResult
    static func write(
        _ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard = .general
    ) -> Bool {
        let marker = NSPasteboard.PasteboardType(CapturePolicy.internalType)
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pb.clearContents()
            pb.declareTypes([.string, marker], owner: nil)
            pb.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url)
            else { return false }
            // Declare what was stored: a HEIC written as PNG is a lie the receiver decodes.
            let uti = NSPasteboard.PasteboardType(item.imageUTI ?? "public.png")
            pb.clearContents()
            pb.declareTypes([uti, marker], owner: nil)
            pb.setData(data, forType: uti)
        }
        pb.setData(Data(), forType: marker)
        // The monitor skips marked writes, so this is the only place a paste re-recencies.
        store.promote(item)
        return true
    }

    /// Synthesize ⌘V, to `pid` alone when given, else through the system tap.
    @MainActor
    static func postCommandV(toPid pid: pid_t? = nil) {
        // Without the grant the events are silently dropped, so ask before spending them.
        guard Permissions.isTrusted() || Permissions.prompt() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
