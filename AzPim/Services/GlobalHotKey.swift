import AzPimCore
import Carbon.HIToolbox
import Foundation

/// The global shortcut of the quick-activate palette, through Carbon `RegisterEventHotKey`: no Accessibility
/// permission and no dependency. Registered on the production launch only (never by snapshots or the test host).
@MainActor
enum GlobalHotKey {
    /// Called on the main thread each time the shortcut is pressed.
    static var onPress: (() -> Void)?
    /// OSStatus of the last registration (`eventHotKeyExistsErr` when another app holds the shortcut), nil when off.
    private(set) static var lastStatus: OSStatus?
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    /// « AZPM »: the signature of our hot key ids.
    private static let signature: OSType = 0x415A_504D

    /// The shortcut stored in `defaults` (unset = ⌃⌥P, « none » = off).
    static func registerStored(_ defaults: UserDefaults = .standard) {
        register(GlobalShortcut.fromStorage(defaults.string(forKey: PreferenceKeys.quickActivateShortcut)))
    }

    /// Replaces the current shortcut; nil turns it off. Returns false when macOS refused it.
    @discardableResult
    static func register(_ shortcut: GlobalShortcut?) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        lastStatus = nil
        guard let shortcut else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, carbonModifiers(shortcut.modifiers),
                                         EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &ref)
        lastStatus = status
        hotKey = status == noErr ? ref : nil
        return status == noErr
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, nil, &handler)
    }

    static func carbonModifiers(_ modifiers: GlobalShortcut.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    fileprivate static func pressed() {
        onPress?()
    }
}

/// Carbon delivers application-target events on the main thread.
private func hotKeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { GlobalHotKey.pressed() }
    return noErr
}
