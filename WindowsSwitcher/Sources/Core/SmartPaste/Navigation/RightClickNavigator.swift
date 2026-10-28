import Foundation
import AppKit
import ApplicationServices

/// 右键跳转执行器。
///
/// 两种策略：
/// 1. **直接写路径**：自定义面板（微信等）顶部中间的路径显示框是可写文本框，
///    写入路径并触发确认动作即可跳转。全程不使用键盘事件，
///    因此不会与系统右键菜单抢按键。
/// 2. **原生面板 ⇧⌘G**：找不到路径框时回退到系统原生「前往文件夹」。
///    该策略依赖合成按键，只有在系统右键菜单被抑制时才安全。
final class RightClickNavigator {

    struct Outcome: Equatable {
        let navigated: Bool
        let strategy: String
        let error: NavigationError?
    }

    private let keyboard: KeyboardSimulator
    private let panelNavigator: NativePanelNavigator

    init(keyboard: KeyboardSimulator = KeyboardSimulator(),
         panelNavigator: NativePanelNavigator = NativePanelNavigator()) {
        self.keyboard = keyboard
        self.panelNavigator = panelNavigator
    }

    /// 执行跳转。
    ///
    /// - Parameter allowKeySynthesis: 是否允许发送合成按键。
    ///   系统右键菜单处于打开状态时合成按键会被菜单吞掉，因此仅在菜单已被抑制时为 true。
    func navigate(to directory: URL,
                  in context: DialogContext,
                  timeout: TimeInterval = 1.5,
                  allowKeySynthesis: Bool = true) async -> Outcome {
        if let match = DialogPathFieldLocator.locate(in: context.window) {
            if writeAndConfirm(directory.path, to: match.element, processID: context.processID, allowKeySynthesis: allowKeySynthesis) {
                return Outcome(navigated: true, strategy: "path-field", error: nil)
            }
        }

        guard allowKeySynthesis else {
            return Outcome(navigated: false, strategy: "none", error: .targetFieldNotFound)
        }

        let outcome = await panelNavigator.navigate(to: directory, in: context, timeout: timeout)
        return Outcome(navigated: outcome.navigated,
                       strategy: "go-to-folder",
                       error: outcome.error)
    }

    /// 写入路径并提交。
    ///
    /// AX 写入不会更新控件内部文本，自绘控件需要走一遍真实键盘输入：
    /// 聚焦 → ⌘A 全选 → 输入路径 → 回车。不允许发送按键时（系统右键菜单打开）
    /// 退回 AX 确认动作。
    private func writeAndConfirm(_ path: String,
                                 to field: AXUIElement,
                                 processID: pid_t,
                                 allowKeySynthesis: Bool) -> Bool {
        let error = SmartAXReader.setValue(path, on: field)
        guard error == .success else {
            return false
        }

        SmartAXReader.setFocused(field)
        Thread.sleep(forTimeInterval: 0.2)

        // 合成按键前确认目标应用仍是前台，避免把路径打进别的应用。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
            return false
        }

        if allowKeySynthesis {
            do {
                try keyboard.selectAll()
                try keyboard.typeText(path)
                try keyboard.sendReturn()
                return true
            } catch {
                return false
            }
        }

        return SmartAXReader.performAction(kAXConfirmAction as String, on: field) == .success
    }
}
