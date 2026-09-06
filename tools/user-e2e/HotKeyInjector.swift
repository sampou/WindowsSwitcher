import ApplicationServices
import Darwin
import Foundation

private enum ExitCode: Int32 {
    case success = 0
    case invalidArguments = 2
    case permissionDenied = 3
    case eventCreationFailed = 4
}

private enum Command: String {
    case status
    case globalReverse = "global-reverse"
    case globalLayout = "global-layout"
    case appReverse = "app-reverse"
}

private struct HotKey {
    let name: String
    let keyCode: CGKeyCode
    let modifier: BaseModifier
}

private enum BaseModifier: String {
    case command
    case option

    var keyCode: CGKeyCode {
        switch self {
        case .command: return KeyCode.leftCommand
        case .option: return KeyCode.leftOption
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        }
    }
}

private enum KeyCode {
    static let leftCommand: CGKeyCode = 55
    static let leftShift: CGKeyCode = 56
    static let leftOption: CGKeyCode = 58
    static let tab: CGKeyCode = 48
    static let grave: CGKeyCode = 50
    static let l: CGKeyCode = 37
}

private enum InjectorError: Error {
    case eventCreationFailed(keyCode: CGKeyCode, keyDown: Bool)
}

private let usage = """
用法：
  hotkey-injector [status]
  hotkey-injector global-reverse [--modifier command|option] [--hold-ms 0...5000]
  hotkey-injector global-layout [--modifier command|option] [--hold-ms 0...5000] [--steps 0...50]
  hotkey-injector app-reverse [--hold-ms 0...5000]

无参数及 status 只检查事件合成权限（通常由“辅助功能”授权），不会发送键鼠事件。
只有 global-reverse、global-layout 和 app-reverse 会执行一次明确的热键注入。
"""

/// 构造并发送单个键盘事件。调用方负责维护完整的按下、释放顺序。
private func postKey(
    source: CGEventSource,
    keyCode: CGKeyCode,
    keyDown: Bool,
    flags: CGEventFlags
) throws {
    guard let event = CGEvent(
        keyboardEventSource: source,
        virtualKey: keyCode,
        keyDown: keyDown
    ) else {
        throw InjectorError.eventCreationFailed(keyCode: keyCode, keyDown: keyDown)
    }

    event.flags = flags
    event.post(tap: .cghidEventTap)
}

/// 异常退出前尽力释放本工具可能按下的修饰键，避免污染用户后续输入。
private func releaseModifiersBestEffort(source: CGEventSource, baseModifier: BaseModifier) {
    try? postKey(
        source: source,
        keyCode: KeyCode.leftShift,
        keyDown: false,
        flags: baseModifier.flag
    )
    try? postKey(
        source: source,
        keyCode: baseModifier.keyCode,
        keyDown: false,
        flags: []
    )
}

/// 发送基础修饰键+Shift+目标键，并严格按目标键、Shift、基础修饰键的逆序释放。
private func sendReverseHotKey(_ hotKey: HotKey, holdMilliseconds: UInt32) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw InjectorError.eventCreationFailed(keyCode: hotKey.keyCode, keyDown: true)
    }

    let baseFlags = hotKey.modifier.flag
    let baseShiftFlags = CGEventFlags(rawValue: baseFlags.rawValue | CGEventFlags.maskShift.rawValue)
    var needsModifierCleanup = false

    do {
        try postKey(
            source: source,
            keyCode: hotKey.modifier.keyCode,
            keyDown: true,
            flags: baseFlags
        )
        needsModifierCleanup = true
        usleep(12_000)

        try postKey(source: source, keyCode: KeyCode.leftShift, keyDown: true, flags: baseShiftFlags)
        usleep(12_000)

        try postKey(source: source, keyCode: hotKey.keyCode, keyDown: true, flags: baseShiftFlags)
        usleep(12_000)
        try postKey(source: source, keyCode: hotKey.keyCode, keyDown: false, flags: baseShiftFlags)
        usleep(12_000)

        if holdMilliseconds > 0 {
            usleep(holdMilliseconds * 1_000)
        }

        try postKey(source: source, keyCode: KeyCode.leftShift, keyDown: false, flags: baseFlags)
        usleep(12_000)
        try postKey(source: source, keyCode: hotKey.modifier.keyCode, keyDown: false, flags: [])
        needsModifierCleanup = false
    } catch {
        if needsModifierCleanup {
            releaseModifiersBestEffort(source: source, baseModifier: hotKey.modifier)
        }
        throw error
    }
}

/// 打开全局切换面板，在基础修饰键保持按下期间发送 L，再释放修饰键。
private func sendGlobalLayoutHotKey(
    _ hotKey: HotKey,
    holdMilliseconds: UInt32,
    additionalSteps: UInt32
) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw InjectorError.eventCreationFailed(keyCode: hotKey.keyCode, keyDown: true)
    }

    let baseFlags = hotKey.modifier.flag
    var needsModifierCleanup = false

    do {
        try postKey(
            source: source,
            keyCode: hotKey.modifier.keyCode,
            keyDown: true,
            flags: baseFlags
        )
        needsModifierCleanup = true
        usleep(12_000)

        try postKey(source: source, keyCode: hotKey.keyCode, keyDown: true, flags: baseFlags)
        usleep(12_000)
        try postKey(source: source, keyCode: hotKey.keyCode, keyDown: false, flags: baseFlags)

        for _ in 0..<additionalSteps {
            usleep(40_000)
            try postKey(source: source, keyCode: hotKey.keyCode, keyDown: true, flags: baseFlags)
            usleep(12_000)
            try postKey(source: source, keyCode: hotKey.keyCode, keyDown: false, flags: baseFlags)
        }

        if holdMilliseconds > 0 {
            usleep(holdMilliseconds * 1_000)
        }

        try postKey(source: source, keyCode: KeyCode.l, keyDown: true, flags: baseFlags)
        usleep(12_000)
        try postKey(source: source, keyCode: KeyCode.l, keyDown: false, flags: baseFlags)
        // 给主线程足够时间把切换面板替换为 Action Panel，再释放全局修饰键。
        usleep(100_000)
        try postKey(source: source, keyCode: hotKey.modifier.keyCode, keyDown: false, flags: [])
        needsModifierCleanup = false
    } catch {
        if needsModifierCleanup {
            releaseModifiersBestEffort(source: source, baseModifier: hotKey.modifier)
        }
        throw error
    }
}

private func printPermissionStatus() -> Bool {
    let granted = CGPreflightPostEventAccess()
    print("post-event-access=\(granted ? "granted" : "denied")")
    return granted
}

private func main() -> ExitCode {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = Command(rawValue: arguments.first ?? Command.status.rawValue) else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return .invalidArguments
    }

    var modifier: BaseModifier
    var requestedHoldMilliseconds: UInt32?
    var additionalSteps: UInt32 = 0
    switch command {
    case .status:
        guard arguments.count <= 1 else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return .invalidArguments
        }
        modifier = .command
    case .globalReverse, .globalLayout:
        modifier = .command
    case .appReverse:
        modifier = .option
    }

    if command != .status {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--modifier" where command == .globalReverse || command == .globalLayout:
                guard index + 1 < arguments.count,
                      let parsedModifier = BaseModifier(rawValue: arguments[index + 1]) else {
                    FileHandle.standardError.write(Data((usage + "\n").utf8))
                    return .invalidArguments
                }
                modifier = parsedModifier
                index += 2
            case "--hold-ms":
                guard index + 1 < arguments.count,
                      let parsedHold = UInt32(arguments[index + 1]),
                      parsedHold <= 5_000 else {
                    FileHandle.standardError.write(Data((usage + "\n").utf8))
                    return .invalidArguments
                }
                requestedHoldMilliseconds = parsedHold
                index += 2
            case "--steps" where command == .globalLayout:
                guard index + 1 < arguments.count,
                      let parsedSteps = UInt32(arguments[index + 1]),
                      parsedSteps <= 50 else {
                    FileHandle.standardError.write(Data((usage + "\n").utf8))
                    return .invalidArguments
                }
                additionalSteps = parsedSteps
                index += 2
            default:
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                return .invalidArguments
            }
        }
    }

    let holdMilliseconds = requestedHoldMilliseconds ?? (command == .globalLayout ? 350 : 0)

    let hasPermission = printPermissionStatus()
    guard command != .status else {
        return hasPermission ? .success : .permissionDenied
    }
    guard hasPermission else {
        FileHandle.standardError.write(
            Data("未发送事件：请先在系统设置的辅助功能权限中授权当前终端。\n".utf8)
        )
        return .permissionDenied
    }

    let hotKey: HotKey
    switch command {
    case .globalReverse:
        hotKey = HotKey(name: command.rawValue, keyCode: KeyCode.tab, modifier: modifier)
    case .globalLayout:
        hotKey = HotKey(name: command.rawValue, keyCode: KeyCode.tab, modifier: modifier)
    case .appReverse:
        hotKey = HotKey(name: command.rawValue, keyCode: KeyCode.grave, modifier: modifier)
    case .status:
        return .success
    }

    do {
        if command == .globalLayout {
            try sendGlobalLayoutHotKey(
                hotKey,
                holdMilliseconds: holdMilliseconds,
                additionalSteps: additionalSteps
            )
            print("sent=\(hotKey.name) keyCode=\(hotKey.keyCode) modifiers=\(hotKey.modifier.rawValue) steps=\(additionalSteps) then=L holdMs=\(holdMilliseconds)")
        } else {
            try sendReverseHotKey(hotKey, holdMilliseconds: holdMilliseconds)
            print("sent=\(hotKey.name) keyCode=\(hotKey.keyCode) modifiers=\(hotKey.modifier.rawValue)+shift holdMs=\(holdMilliseconds)")
        }
        return .success
    } catch InjectorError.eventCreationFailed(let keyCode, let keyDown) {
        FileHandle.standardError.write(
            Data("事件创建失败：keyCode=\(keyCode) keyDown=\(keyDown)；修饰键已尽力释放。\n".utf8)
        )
        return .eventCreationFailed
    } catch {
        FileHandle.standardError.write(Data("事件发送失败：\(error)；修饰键已尽力释放。\n".utf8))
        return .eventCreationFailed
    }
}

exit(main().rawValue)
