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

    /// 转换为 AppKit 原生菜单使用的主键字符。
    ///
    /// 返回 `nil` 时菜单仍可显示和点击，只是不展示无法识别的快捷键。
    var menuKeyEquivalent: String? {
        switch Int(keyCode) {
        case kVK_Tab: return "\t"
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Escape: return "\u{1B}"
        case kVK_Delete: return "\u{7F}"
        case kVK_ANSI_Grave: return "`"
        case kVK_LeftArrow: return Self.functionKey(NSLeftArrowFunctionKey)
        case kVK_RightArrow: return Self.functionKey(NSRightArrowFunctionKey)
        case kVK_UpArrow: return Self.functionKey(NSUpArrowFunctionKey)
        case kVK_DownArrow: return Self.functionKey(NSDownArrowFunctionKey)
        case kVK_F1: return Self.functionKey(NSF1FunctionKey)
        case kVK_F2: return Self.functionKey(NSF2FunctionKey)
        case kVK_F3: return Self.functionKey(NSF3FunctionKey)
        case kVK_F4: return Self.functionKey(NSF4FunctionKey)
        case kVK_F5: return Self.functionKey(NSF5FunctionKey)
        case kVK_F6: return Self.functionKey(NSF6FunctionKey)
        case kVK_F7: return Self.functionKey(NSF7FunctionKey)
        case kVK_F8: return Self.functionKey(NSF8FunctionKey)
        case kVK_F9: return Self.functionKey(NSF9FunctionKey)
        case kVK_F10: return Self.functionKey(NSF10FunctionKey)
        case kVK_F11: return Self.functionKey(NSF11FunctionKey)
        case kVK_F12: return Self.functionKey(NSF12FunctionKey)
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return nil
        }
    }

    /// 转换为 AppKit 原生菜单的修饰键掩码。
    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if normalizedModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if normalizedModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if normalizedModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if normalizedModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    private static func functionKey(_ value: Int) -> String? {
        UnicodeScalar(value).map(String.init)
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
