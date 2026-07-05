import Carbon.HIToolbox
import Foundation

/// Global preset hotkeys via Carbon RegisterEventHotKey (works without
/// Accessibility permission, unlike NSEvent global monitors).
/// Scheme: ⌘⌃1 … ⌘⌃9 activate the first nine presets.
final class HotkeyManager {
    static let shared = HotkeyManager()
    var onHotkey: ((Int) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    // Virtual key codes for the 1…9 number row
    private let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    func registerPresetHotkeys(count: Int) {
        installHandlerIfNeeded()
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        for i in 0..<min(count, keyCodes.count) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5045_5148), id: UInt32(i)) // 'PEQH'
            if RegisterEventHotKey(keyCodes[i], UInt32(cmdKey | controlKey), id,
                                   GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                hotKeyRefs.append(ref)
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let index = Int(hkID.id)
            DispatchQueue.main.async { mgr.onHotkey?(index) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }
}
