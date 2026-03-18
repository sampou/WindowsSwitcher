import AppKit
import Carbon

struct HotKey {
    let keyCode: UInt32
    let modifiers: UInt32
    let identifier: String
}

class HotKeyManager {
    private var registeredHotKeys: [UInt32: EventHotKeyRef] = [:]  // id -> ref
    private var actions: [UInt32: () -> Void] = [:]                // id -> action
    private var identifierToID: [String: UInt32] = [:]             // identifier -> id
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    // 四字节签名，唯一标识本应用的热键
    private let signature: OSType = 0x5753574B // "WSWK"

    init() {
        setupEventHandler()
    }

    func register(_ hotKey: HotKey, action: @escaping () -> Void) {
        // 若已注册同名快捷键，先注销
        unregister(hotKey.identifier)

        let currentID = nextID
        nextID += 1

        let eventID = EventHotKeyID(signature: signature, id: currentID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers,
            eventID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Logger.error("Failed to register hotkey: \(hotKey.identifier)")
            return
        }
        registeredHotKeys[currentID] = ref
        actions[currentID] = action
        identifierToID[hotKey.identifier] = currentID
        Logger.info("Registered hotkey: \(hotKey.identifier) id=\(currentID)")
    }

    func unregister(_ identifier: String) {
        guard let id = identifierToID[identifier] else { return }
        if let ref = registeredHotKeys[id] { UnregisterEventHotKey(ref) }
        registeredHotKeys.removeValue(forKey: id)
        actions.removeValue(forKey: id)
        identifierToID.removeValue(forKey: identifier)
    }

    private func setupEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                // 只响应本应用注册的热键
                guard hotKeyID.signature == manager.signature else { return noErr }
                manager.actions[hotKeyID.id]?()
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        registeredHotKeys.values.forEach { UnregisterEventHotKey($0) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }
}
