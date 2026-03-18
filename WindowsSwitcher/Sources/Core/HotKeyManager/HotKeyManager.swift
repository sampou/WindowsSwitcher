import AppKit
import Carbon

struct HotKey {
    let keyCode: UInt32
    let modifiers: UInt32
    let identifier: String
}

class HotKeyManager {
    private var registeredHotKeys: [String: EventHotKeyRef] = [:]
    private var actions: [String: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        setupEventHandler()
    }

    func register(_ hotKey: HotKey, action: @escaping () -> Void) {
        let id = EventHotKeyID(signature: OSType(hotKey.keyCode), id: UInt32(registeredHotKeys.count + 1))
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        registeredHotKeys[hotKey.identifier] = ref
        actions[hotKey.identifier] = action
    }

    func unregister(_ identifier: String) {
        if let ref = registeredHotKeys[identifier] {
            UnregisterEventHotKey(ref)
            registeredHotKeys.removeValue(forKey: identifier)
            actions.removeValue(forKey: identifier)
        }
    }

    private func setupEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            manager.actions.values.forEach { $0() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit {
        registeredHotKeys.values.forEach { UnregisterEventHotKey($0) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }
}
