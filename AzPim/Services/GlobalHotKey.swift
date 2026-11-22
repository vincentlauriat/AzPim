import AzPimCore
import Carbon.HIToolbox
import Foundation

/// The global shortcut of the quick-activate palette, through Carbon `RegisterEventHotKey`: no Accessibility
/// permission and no dependency. Registered on the production launch only (never by snapshots or the test host).
@MainActor
enum GlobalHotKey {
    /// Called on the main thread each time the shortcut is pressed.
    static var onPress: (() -> Void)?
    /// OSStatus of the last failed registration (`eventHotKeyExistsErr` when the shortcut is taken), nil after a success.
    private(set) static var lastError: OSStatus?
    /// The shortcut registered now, nil when off.
    private(set) static var current: GlobalShortcut?
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    /// « AZPM »: the signature of our hot key ids.
    static let signature: OSType = 0x415A_504D
    /// Id of the registered hot key; each registration takes a new one, so a press of the old one is never taken.
    private(set) static var currentId: UInt32 = 0

    /// The shortcut stored in `defaults` (unset = ⌃⌥P, « none » = off).
    static func registerStored(_ defaults: UserDefaults = .standard) {
        register(GlobalShortcut.fromStorage(defaults.string(forKey: PreferenceKeys.quickActivateShortcut)))
    }

    /// Replaces the current shortcut; nil turns it off. The new one is registered first and the old one released only
    /// once it is: when macOS refuses (taken by another app), the old shortcut keeps working. Returns noErr or the
    /// refusal.
    @discardableResult
    static func register(_ shortcut: GlobalShortcut?) -> OSStatus {
        guard let shortcut else {
            release()
            lastError = nil
            return noErr
        }
        if shortcut == current, hotKey != nil { return noErr }
        let installed = installHandler()
        guard installed == noErr else {
            lastError = installed
            return installed
        }
        var ref: EventHotKeyRef?
        let id = currentId &+ 1
        let status = RegisterEventHotKey(shortcut.keyCode, carbonModifiers(shortcut.modifiers),
                                         EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            lastError = status == noErr ? OSStatus(eventInternalErr) : status
            return lastError ?? status
        }
        release()
        hotKey = ref
        current = shortcut
        currentId = id
        lastError = nil
        return noErr
    }

    private static func release() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        current = nil
    }

    private static func installHandler() -> OSStatus {
        guard handler == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, nil, &handler)
    }

    static func carbonModifiers(_ modifiers: GlobalShortcut.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    /// Only our current hot key opens the palette; any other id goes on to the next handler.
    fileprivate static func pressed(_ id: EventHotKeyID) -> Bool {
        guard id.signature == signature, id.id == currentId, hotKey != nil else { return false }
        onPress?()
        return true
    }
}

/// Carbon delivers application-target events on the main thread.
private func hotKeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let pressedId = id
    let handled = MainActor.assumeIsolated { GlobalHotKey.pressed(pressedId) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
