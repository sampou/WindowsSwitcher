import Foundation
import AppKit
import ApplicationServices

/// 原生与自定义文件面板的目录导航执行器。
///
/// 复用应用自己对 ⇧⌘G 的响应——这是 macOS 平台惯例，各家应用都会实现：
/// - 原生 NSOpenPanel：弹出「前往文件夹」子面板，里面的路径输入框初始为空；
/// - 自绘面板（如 Notepad Next）：在同一个窗口顶部显现一行可写路径，预填为当前路径。
///
/// 两种形态都用同一套定位规则（`DialogPathFieldLocator`）识别，代码不做应用分支。
final class NativePanelNavigator {

    struct Outcome: Equatable {
        /// 是否已经执行了跳转动作。
        let navigated: Bool
        /// 是否成功校验出当前目录确实为目标目录。
        let verified: Bool
        let error: NavigationError?

        static let notNavigated = Outcome(navigated: false, verified: false, error: .verificationFailed)
    }

    /// 找到的路径输入框。
    private struct PathField {
        let element: AXUIElement
        /// 是否位于独立子面板中（独立面板优先用 AX 确认动作提交，避免多余按键）。
        let isSheet: Bool
    }

    private let keyboard: KeyboardSimulator

    /// 提交之后的校验窗口（秒）。
    ///
    /// 与「查找路径框」的超时分开：逐字输入路径本身就要一两秒，
    /// 校验必须留出独立的等待时间，否则会误判为失败。
    private static let verificationTimeout: TimeInterval = 2.0

    init(keyboard: KeyboardSimulator = KeyboardSimulator()) {
        self.keyboard = keyboard
    }

    func navigate(to directory: URL,
                  in context: DialogContext,
                  timeout: TimeInterval = 1.5) async -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)

        guard isForeground(processID: context.processID) else {
            return Outcome(navigated: false, verified: false, error: .focusChanged)
        }

        do {
            try keyboard.openGoToFolder()
        } catch {
            return Outcome(navigated: false, verified: false, error: .keyboardSynthesisFailed)
        }

        guard let field = await waitForPathField(processID: context.processID, deadline: deadline) else {
            return Outcome(navigated: false, verified: false, error: .targetFieldNotFound)
        }

        do {
            try submit(path: directory.path, to: field, processID: context.processID)
        } catch let error as NavigationError {
            return Outcome(navigated: false, verified: false, error: error)
        } catch {
            return Outcome(navigated: false, verified: false, error: .axOperationFailed(-1))
        }

        var verified = await verify(processID: context.processID,
                                    expected: directory,
                                    deadline: Date().addingTimeInterval(Self.verificationTimeout))

        // 第一次提交可能因为控件刚创建、焦点还没落实而丢失键盘输入，
        // 路径框仍然开着就是明确信号——重新取一次句柄再提交一次。
        if !verified, let retryField = findPathField(processID: context.processID) {
            Logger.operation("智能粘贴",
                             detail: "路径框仍打开，重试提交",
                             result: "第 2 次")
            do {
                try submit(path: directory.path, to: retryField, processID: context.processID)
            } catch {
                // 重试失败就按未验证处理。
            }
            verified = await verify(processID: context.processID,
                                    expected: directory,
                                    deadline: Date().addingTimeInterval(Self.verificationTimeout))
        }

        return Outcome(navigated: true,
                       verified: verified,
                       error: verified ? nil : .verificationFailed)
    }

    // MARK: - 步骤

    /// 等待路径输入框出现。
    ///
    /// ⇧⌘G 之后，应用可能弹出独立子面板，也可能在当前窗口内联显现路径框，
    /// 两种都要找。找到后再等一小段时间重新取一次句柄——刚创建出来的元素
    /// 可能还没准备好接受键盘输入。
    private func waitForPathField(processID: pid_t, deadline: Date) async -> PathField? {
        while Date() < deadline {
            if let field = findPathField(processID: processID) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return findPathField(processID: processID) ?? field
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return nil
    }

    /// 在应用窗口中查找路径输入框。
    private func findPathField(processID: pid_t) -> PathField? {
        let app = AXUIElementCreateApplication(processID)

        for window in SmartAXReader.children(of: app) {
            let isSheet = isSheetWindow(window)

            // 内联路径框：值预填为路径，用严格规则。
            if let match = DialogPathFieldLocator.locate(in: window, allowEmpty: false) {
                return PathField(element: match.element, isSheet: isSheet)
            }
            // 独立子面板里的路径框：初始为空，允许空值。
            if isSheet, let match = DialogPathFieldLocator.locate(in: window, allowEmpty: true) {
                return PathField(element: match.element, isSheet: true)
            }
        }

        return nil
    }

    /// 是否是独立子面板（sheet / 对话框），而不是主文件面板窗口。
    private func isSheetWindow(_ window: AXUIElement) -> Bool {
        let subrole = SmartAXReader.subrole(of: window)
        return subrole == "AXDialog" || subrole == "AXSystemDialog"
    }

    /// 写入路径并提交。
    ///
    /// 关键点一：AX 写入（`setValue`）只更新辅助功能属性，**不会更新控件内部的文本**。
    /// 自绘控件（Notepad Next 的内联路径框是 Qt 控件）在回车时读的是内部文本，
    /// 因此只写 AX 值再回车是没有效果的。必须先让路径框获得焦点，再用键盘
    /// ⌘A 全选 + 输入路径 + 回车，走一遍真实用户路径。
    ///
    /// 关键点二：不能用"窗口是 AXDialog"来判断该不该走 AX 确认动作——Notepad Next
    /// 的「打开」面板本身就是 AXDialog，但它的路径框是**内联**的，对文本框执行
    /// AX 确认动作会返回成功却什么也不做。因此统一走键盘路径。
    private func submit(path: String, to field: PathField, processID: pid_t) throws {
        // 写入前确认目标应用仍是前台：整段流程要花一两秒，期间用户可能切走，
        // 那时继续合成按键就会把路径打进无关的应用。
        guard isForeground(processID: processID) else {
            throw NavigationError.focusChanged
        }

        // 先用 AX 写入目标路径：既是给用户的即时反馈，也让"当前焦点元素是不是
        // 这个路径框"可以被读回校验。
        let error = SmartAXReader.setValue(path, on: field.element)
        guard error == .success else {
            throw NavigationError.axOperationFailed(Int(error.rawValue))
        }

        // 路径框必须持有焦点，否则键盘输入不会落到它上面。
        ensureFocused(field.element, expectedValue: path)
        Thread.sleep(forTimeInterval: 0.2)

        guard isForeground(processID: processID) else {
            throw NavigationError.focusChanged
        }

        // 走一遍真实用户路径：⌘A 全选 → 逐字输入 → 回车。
        // 逐字输入后回读校验：输入太快或控件未就绪时会丢字符，路径拼错等于没跳转。
        try keyboard.selectAll()
        try keyboard.typeText(path)
        Thread.sleep(forTimeInterval: 0.3)

        var current = SmartAXReader.value(of: field.element) ?? ""
        if current != path {
            Logger.warning("智能粘贴: 路径输入不完整（当前长度 \(current.count)，目标 \(path.count)），清空后重试")
            try keyboard.clearInput(characterCount: current.count + 4)
            try keyboard.typeText(path)
            Thread.sleep(forTimeInterval: 0.3)
            current = SmartAXReader.value(of: field.element) ?? ""
        }

        try keyboard.sendReturn()

        Logger.operation("智能粘贴",
                         detail: "已提交路径",
                         result: current == path ? "路径框值与目标一致" : "路径框值=\(current)")
    }

    /// 让路径框真正拿到键盘焦点。
    ///
    /// 只调用 `kAXFocused` 并不保证焦点已经落实（控件刚创建时常见），
    /// 这里通过系统级焦点元素回读来确认，必要时重试。
    private func ensureFocused(_ field: AXUIElement, expectedValue: String) {
        for attempt in 1...3 {
            if let focused = SmartAXReader.focusedElement(),
               SmartAXReader.role(of: focused) == "AXTextField",
               (SmartAXReader.value(of: focused) ?? "") == expectedValue {
                Logger.operation("智能粘贴", detail: "路径框已聚焦", result: "第 \(attempt) 次尝试")
                return
            }
            SmartAXReader.setFocused(field)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Logger.warning("智能粘贴: 路径框未能确认获得焦点")
    }

    /// 校验当前目录确实已切换到目标目录。
    ///
    /// 优先读 `AXDocument`（原生面板提供当前目录）。部分自绘面板（Notepad Next）
    /// 不暴露该属性，此时退化为「路径框已关闭」这一间接信号——路径框关闭说明
    /// 应用已接受路径并完成跳转。两者都拿不到证据时返回 false（无法确认），
    /// 不谎报成功。
    private func verify(processID: pid_t, expected: URL, deadline: Date) async -> Bool {
        let expectedPath = expected.standardizedFileURL.path

        while Date() < deadline {
            if let document = currentDocument(processID: processID) {
                if document == expectedPath {
                    return true
                }
            } else if findPathField(processID: processID) == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        return false
    }

    /// 读取文件面板当前目录（排除仍处于 sheet 状态的窗口）。
    private func currentDocument(processID: pid_t) -> String? {
        let app = AXUIElementCreateApplication(processID)

        for window in SmartAXReader.children(of: app) {
            if isSheetWindow(window) {
                continue
            }
            if let document = SmartAXReader.document(of: window), document.hasPrefix("/") {
                return document
            }
        }

        return nil
    }

    /// 前台进程是否仍然是原进程。
    private func isForeground(processID: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    }
}
