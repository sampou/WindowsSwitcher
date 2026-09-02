import AppKit
import Carbon
import Foundation

/// 可持久化的按键组合。
struct KeyChord: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Carbon 使用的标准化修饰键掩码。
    var normalizedModifiers: UInt32 {
        modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey)
    }

    /// 判断 AppKit 键盘事件是否与该组合完全一致。
    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode && Self.carbonModifiers(from: event.modifierFlags) == normalizedModifiers
    }

    /// 将 AppKit 修饰键转换成 Carbon 修饰键掩码。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    /// 生成人类可读的快捷键文本。
    var displayText: String {
        HotKeyFormatter.format(keyCode: keyCode, modifiers: normalizedModifiers)
    }
}

/// 窗口布局快捷键默认值。
enum WindowLayoutHotKeyDefaults {
    static let controlOption = UInt32(controlKey | optionKey)
    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
    static let openPanel = KeyChord(keyCode: 37, modifiers: controlOption)

    static let commands: [String: KeyChord] = [
        WindowLayoutActionID.leftHalf.rawValue: .init(keyCode: 123, modifiers: controlOption),
        WindowLayoutActionID.rightHalf.rawValue: .init(keyCode: 124, modifiers: controlOption),
        WindowLayoutActionID.topHalf.rawValue: .init(keyCode: 126, modifiers: controlOption),
        WindowLayoutActionID.bottomHalf.rawValue: .init(keyCode: 125, modifiers: controlOption),
        WindowLayoutActionID.topLeftQuarter.rawValue: .init(keyCode: 32, modifiers: controlOption),
        WindowLayoutActionID.topRightQuarter.rawValue: .init(keyCode: 34, modifiers: controlOption),
        WindowLayoutActionID.bottomLeftQuarter.rawValue: .init(keyCode: 38, modifiers: controlOption),
        WindowLayoutActionID.bottomRightQuarter.rawValue: .init(keyCode: 40, modifiers: controlOption),
        WindowLayoutActionID.maximize.rawValue: .init(keyCode: 36, modifiers: controlOption),
        WindowLayoutActionID.center.rawValue: .init(keyCode: 8, modifiers: controlOption),
        WindowLayoutActionID.previousDisplay.rawValue: .init(keyCode: 123, modifiers: controlOptionCommand),
        WindowLayoutActionID.nextDisplay.rawValue: .init(keyCode: 124, modifiers: controlOptionCommand)
    ]
}

/// 窗口布局快捷键配置。
///
/// 命令字典缺少某个已知 ID 表示用户主动清除了该快捷键；未知 ID 会被保留但不会注册。
struct WindowLayoutHotKeyConfig: Codable, Equatable {
    var isEnabled: Bool = true
    var openPanel: KeyChord? = WindowLayoutHotKeyDefaults.openPanel
    var commands: [String: KeyChord] = WindowLayoutHotKeyDefaults.commands

    /// 恢复全部默认快捷键。
    mutating func resetToDefaults() {
        self = WindowLayoutHotKeyConfig()
    }

    /// 返回指定动作当前配置的快捷键。
    func chord(for id: WindowLayoutActionID) -> KeyChord? {
        commands[id.rawValue]
    }

    /// 设置或清除指定动作的快捷键。
    mutating func setChord(_ chord: KeyChord?, for id: WindowLayoutActionID) {
        if let chord {
            commands[id.rawValue] = chord
        } else {
            commands.removeValue(forKey: id.rawValue)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, openPanel, commands
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        openPanel = container.contains(.openPanel)
            ? try container.decodeIfPresent(KeyChord.self, forKey: .openPanel)
            : WindowLayoutHotKeyDefaults.openPanel
        commands = container.contains(.commands)
            ? try container.decode([String: KeyChord].self, forKey: .commands)
            : WindowLayoutHotKeyDefaults.commands
    }
}
