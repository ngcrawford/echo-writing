import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (SPEC §5.1). Carbon's hot keys work from any app and, unlike a global
/// key monitor, need no extra permission.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code such as `kVK_ANSI_E`.
    ///   - modifiers: Carbon modifier flags such as `controlKey | optionKey`.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &eventType, refcon, &handlerRef) == noErr
        else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4543_484F), id: 1)   // "ECHO"
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr
        else {
            RemoveEventHandler(handlerRef)
            return nil
        }
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    fileprivate func fire() { action() }
}

/// Carbon delivers hot keys on the main thread.
private let hotKeyCallback: EventHandlerUPP = { _, _, refcon in
    guard let refcon else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.fire() }
    return noErr
}
