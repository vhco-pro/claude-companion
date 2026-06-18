import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey via Carbon's RegisterEventHotKey (fires regardless of focused app and,
/// unlike NSEvent global monitors, needs no Accessibility permission). Default ⌃⌥⌘A drives the
/// auto-accept kill switch. Rebinding via config.yaml is a follow-up.
public final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void

    public init(onFire: @escaping () -> Void) { self.onFire = onFire }

    /// keyCode 0 == 'A'. `modifiers` are Carbon masks (cmdKey/optionKey/controlKey/shiftKey).
    public func register(keyCode: UInt32 = UInt32(kVK_ANSI_A),
                         modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey)) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue().onFire()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x43434B59), id: 1) // 'CCKY'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }

    deinit { unregister() }
}
