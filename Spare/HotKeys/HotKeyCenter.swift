import Carbon.HIToolbox

/// C entry point: decode the `EventRef` to a plain value before crossing into actor code.
/// Carbon calls this on the main run loop's event dispatcher and wants an `OSStatus` back, so
/// there is nowhere to await — `MainActor.assumeIsolated` states that guarantee rather than
/// hopping. This and `ClipboardMonitor`'s poll timer are the only two in the app.
private func hotKeyEventHandler(
    _: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let error = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard error == noErr else { return error }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { center.handle(hotKeyID) }
}

/// The Carbon layer for Spare's one global shortcut: the palette toggle. Which chord that is
/// belongs to `Settings`; this only registers what it is handed and calls `onPress`.
@MainActor
final class HotKeyCenter {
    /// Set by AppCore. Fires on key-down, on the main actor, once per press.
    var onPress: (() -> Void)?

    /// While true the chord is soft-unregistered, so the recorder can capture it as a key-down.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { deactivate() } else { activate() }
        }
    }

    private(set) var shortcut: KeyShortcut?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// FourCC "SPRE". Carbon matches on it, so a stale id from another app cannot fire ours.
    private let signature: OSType = 0x5350_5245
    private let hotKeyID: UInt32 = 1

    // Isolated so teardown may touch the main-actor Carbon refs.
    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Point the one registration at `shortcut`, dropping the previous chord first so the old
    /// combo never stays live. A nil shortcut leaves the app with no global hotkey at all.
    func rebind(_ shortcut: KeyShortcut?) {
        deactivate()
        self.shortcut = shortcut
        if !isPaused { activate() }
    }

    private func activate() {
        guard hotKeyRef == nil, let shortcut else { return }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let error = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            UInt32(shortcut.modifiers),
            EventHotKeyID(signature: signature, id: hotKeyID),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        // Another app may already own the combo. The binding stays on screen but does not
        // fire, which is the only outcome Carbon offers us short of stealing it.
        guard error == noErr, let ref else {
            NSLog("Spare: could not register %@ (OSStatus %d)", shortcut.displayString, error)
            return
        }
        hotKeyRef = ref
    }

    private func deactivate() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil, let dispatcher = GetEventDispatcherTarget() else { return }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]
        InstallEventHandler(
            dispatcher,
            hotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    /// Returning `eventNotHandledErr` for anything else lets the key through to the focused app.
    fileprivate func handle(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == signature, id.id == hotKeyID, let onPress else {
            return OSStatus(eventNotHandledErr)
        }
        onPress()
        return noErr
    }
}
