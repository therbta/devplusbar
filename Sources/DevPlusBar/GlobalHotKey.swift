import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut through Carbon's hot key API, which needs no Accessibility permission.
@MainActor
final class GlobalHotKey {
    nonisolated(unsafe) private var ref: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌥⌘D by default.
    init(keyCode: Int = kVK_ANSI_D, modifiers: Int = optionKey | cmdKey, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action() } }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x44504221), id: 1) // "DPB!"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Dev+ Bar: global shortcut not registered (\(status)); another app may own it") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
