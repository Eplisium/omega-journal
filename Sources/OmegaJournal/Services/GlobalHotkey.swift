import AppKit
import Carbon.HIToolbox

/// ⌥⌘J — a system-wide "new entry" hotkey (Carbon `RegisterEventHotKey`; needs no accessibility permission).
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    static let enabledKey = "shell.globalHotkeyEnabled"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func syncRegistration() {
        Self.isEnabled ? register() : unregister()
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                NotificationCenter.default.post(name: .newEntry, object: nil)
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4F4D4547), id: 1)   // 'OMEG'
        RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}
