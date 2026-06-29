import AppKit
import Carbon.HIToolbox

/// A system-wide (global) hot key built on Carbon's `RegisterEventHotKey`.
///
/// Why Carbon and not `NSEvent.addGlobalMonitorForEvents` or `CGEventTap`:
///   - Carbon hot keys fire even when the app is in the background, and do
///     **not** require Accessibility / Input-Monitoring permission.
///   - They are a real OS-level registration, so the shortcut is reserved
///     globally rather than merely observed.
///
/// The C event handler can't capture Swift context, so we route the fired
/// hot-key id through a static registry back to the owning instance.
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void
    private let id: UInt32

    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// 'STKB' four-char-code signature for our hot keys.
    private static let signature: OSType =
        OSType("STKB".utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) })

    /// - Parameters:
    ///   - keyCode: virtual key code, e.g. `UInt32(kVK_ANSI_S)`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | optionKey)`.
    ///   - handler: invoked on the main thread when the hot key is pressed.
    /// - Returns: nil if the OS refused to register the combo (e.g. already taken).
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1

        GlobalHotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, hotKeyRef != nil else { return nil }
        GlobalHotKey.registry[id] = self
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        GlobalHotKey.registry[id] = nil
    }

    /// Installs the single process-wide Carbon event handler that dispatches
    /// every hot-key press to the matching instance. The closure captures no
    /// context so it is convertible to a C function pointer.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let st = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard st == noErr else { return st }
            let targetID = hkID.id
            DispatchQueue.main.async {
                GlobalHotKey.registry[targetID]?.handler()
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            nil
        )
        handlerInstalled = true
    }
}
