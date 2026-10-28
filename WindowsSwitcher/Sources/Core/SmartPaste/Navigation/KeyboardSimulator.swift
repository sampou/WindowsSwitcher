import Foundation
import CoreGraphics

enum KeyboardSimulatorError: Error {
    case eventCreationFailed
}

/// 键盘事件合成。
///
/// 只合成必要的组合键，不模拟鼠标点击：鼠标点击会受窗口尺寸、缩放与多显示器影响。
///
/// 事件一律从 `.cghidEventTap` 注入——与真实硬件输入同级，目标应用会把它当作
/// 真正的键盘输入处理（Qt 等自绘控件只认这种输入；用会话级注入时按键可能不被接受）。
struct KeyboardSimulator {

    /// ANSI 键盘上的 G 键虚拟键码。
    static let goToFolderKeyCode: CGKeyCode = 5
    /// Return 键虚拟键码。
    static let returnKeyCode: CGKeyCode = 36
    /// ANSI 键盘上的 A 键虚拟键码。
    static let selectAllKeyCode: CGKeyCode = 0
    /// End 键虚拟键码（移到行尾）。
    static let endKeyCode: CGKeyCode = 115
    /// 退格键虚拟键码。
    static let deleteKeyCode: CGKeyCode = 51

    /// 合成一次按键。
    ///
    /// 事件源用 `.hidSystemState`（硬件级来源）：用 `.privateState` 合成的事件
    /// 会被部分应用（Qt 自绘控件）识别为非真实输入而丢弃。
    func send(keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: source,
                                virtualKey: keyCode,
                                keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                              virtualKey: keyCode,
                              keyDown: false) else {
            throw KeyboardSimulatorError.eventCreationFailed
        }

        down.flags = flags
        up.flags = flags

        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    /// 打开系统原生的「前往文件夹」面板（⇧⌘G）。
    func openGoToFolder() throws {
        try send(keyCode: Self.goToFolderKeyCode,
                 flags: [.maskCommand, .maskShift])
    }

    /// 提交当前输入。
    func sendReturn() throws {
        try send(keyCode: Self.returnKeyCode)
    }

    /// 全选当前输入框内容（⌘A）。
    func selectAll() throws {
        try send(keyCode: Self.selectAllKeyCode, flags: [.maskCommand])
        // 给目标控件一点处理全选的时间，否则紧接着的输入可能落在旧选区上。
        usleep(120_000)
    }

    /// 清空输入框内容。
    ///
    /// 先移到行尾，再连续退格。用退格而不是依赖 ⌘A——部分自绘控件不把 ⌘A
    /// 当成"全选文本"，导致后续输入插在光标处而不是替换。
    func clearInput(characterCount: Int) throws {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let endDown = CGEvent(keyboardEventSource: source, virtualKey: Self.endKeyCode, keyDown: true),
              let endUp = CGEvent(keyboardEventSource: source, virtualKey: Self.endKeyCode, keyDown: false) else {
            throw KeyboardSimulatorError.eventCreationFailed
        }
        endDown.post(tap: .cghidEventTap)
        usleep(20_000)
        endUp.post(tap: .cghidEventTap)
        usleep(60_000)

        let count = max(characterCount, 1)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.deleteKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.deleteKeyCode, keyDown: false) else {
                throw KeyboardSimulatorError.eventCreationFailed
            }
            down.post(tap: .cghidEventTap)
            usleep(12_000)
            up.post(tap: .cghidEventTap)
            usleep(18_000)
        }
        usleep(80_000)
    }

    /// 逐字符输入文本。
    ///
    /// 使用 Unicode 字符串注入，与当前键盘布局无关。
    /// 字符之间留出间隔——输入太快时部分控件会丢字符，路径会被拼错。
    func typeText(_ text: String) throws {
        let source = CGEventSource(stateID: .hidSystemState)

        for character in text {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source,
                                    virtualKey: 0,
                                    keyDown: true),
                  let up = CGEvent(keyboardEventSource: source,
                                  virtualKey: 0,
                                  keyDown: false) else {
                throw KeyboardSimulatorError.eventCreationFailed
            }

            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)

            down.post(tap: .cghidEventTap)
            usleep(25_000)
            up.post(tap: .cghidEventTap)
            usleep(25_000)
        }

        // 让控件处理完最后一批字符再提交。
        usleep(200_000)
    }
}
