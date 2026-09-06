import AppKit
import Carbon

// MARK: - SkyLight 私有 API
/// 用于禁用/启用系统级快捷键
/// 参考：AltTab 实现 (https://github.com/lwouis/alt-tab-macos)

/// 系统快捷键标识符
enum CGSSymbolicHotKey: Int, CaseIterable {
    case commandTab = 1        // Command+Tab (应用切换器)
    case commandShiftTab = 2   // Command+Shift+Tab (反向应用切换)
    case commandKeyAboveTab = 6  // Command+` (同应用窗口切换)
}

/// 私有 API：启用/禁用系统快捷键
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
@discardableResult
func CGSSymbolicHotKeyEnabled(_ hotKey: Int, _ isEnabled: Bool) -> CGError

/// 禁用或启用系统的 Command+Tab 快捷键
func setNativeCommandTabEnabled(_ isEnabled: Bool) {
    print("[SkyLight] Setting native Command+Tab enabled: \(isEnabled)")
    let result1 = CGSSymbolicHotKeyEnabled(CGSSymbolicHotKey.commandTab.rawValue, isEnabled)
    let result2 = CGSSymbolicHotKeyEnabled(CGSSymbolicHotKey.commandShiftTab.rawValue, isEnabled)
    if result1 != .success || result2 != .success {
        print("[SkyLight] Warning: Failed to set native Command+Tab: \(result1.rawValue), \(result2.rawValue)")
    }
}

/// 禁用或启用系统的 Command+` 快捷键
func setNativeCommandGraveEnabled(_ isEnabled: Bool) {
    print("[SkyLight] Setting native Command+` enabled: \(isEnabled)")
    let result = CGSSymbolicHotKeyEnabled(CGSSymbolicHotKey.commandKeyAboveTab.rawValue, isEnabled)
    if result != .success {
        print("[SkyLight] Warning: Failed to set native Command+`: \(result.rawValue)")
    }
}

/// 禁用所有系统快捷键（在应用激活时调用）
func disableAllSystemHotKeys() {
    setNativeCommandTabEnabled(false)
    setNativeCommandGraveEnabled(false)
}

/// 恢复所有系统快捷键（在应用退出时调用）
func restoreAllSystemHotKeys() {
    setNativeCommandTabEnabled(true)
    setNativeCommandGraveEnabled(true)
}

// MARK: - HotKey

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

    /// 注册全局快捷键，并返回 Carbon 是否接受该组合。
    @discardableResult
    func register(_ hotKey: HotKey, action: @escaping () -> Void) -> Bool {
        // 若已注册同名快捷键，先注销
        unregister(hotKey.identifier)

        let currentID = nextID
        nextID += 1

        let eventID = EventHotKeyID(signature: signature, id: currentID)
        var ref: EventHotKeyRef?
        // 使用 GetEventDispatcherTarget() 替代 GetApplicationEventTarget()
        // 这样可以在系统调度器级别注册快捷键，能够拦截系统快捷键如 Command+Tab
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers,
            eventID, GetEventDispatcherTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Logger.error("Failed to register hotkey: \(hotKey.identifier), status=\(status)")
            return false
        }
        registeredHotKeys[currentID] = ref
        actions[currentID] = action
        identifierToID[hotKey.identifier] = currentID
        Logger.info("Registered hotkey: \(hotKey.identifier) id=\(currentID)")
        return true
    }

    /// 查询指定标识符当前是否注册成功。
    func isRegistered(_ identifier: String) -> Bool {
        identifierToID[identifier] != nil
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
            GetEventDispatcherTarget(),
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
