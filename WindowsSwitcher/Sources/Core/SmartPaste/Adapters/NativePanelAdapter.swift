import Foundation
import ApplicationServices

/// 原生 AppKit 文件面板适配器（L1）。
///
/// 识别依据是辅助功能结构而不是窗口标题：标题受语言、系统版本与应用定制影响，
/// 不可作为拦截依据。
final class NativePanelAdapter: FileDialogAdapter {

    let identifier = "native.panel"

    /// 原生面板可能出现在任意应用中，因此不做 bundleID 限制。
    func supportsApplication(bundleID: String, processID: pid_t) -> Bool {
        true
    }

    private let navigator: NativePanelNavigator

    init(navigator: NativePanelNavigator) {
        self.navigator = navigator
    }

    func detect(_ context: DialogContext) -> AdapterConfidence {
        guard let subrole = SmartAXReader.subrole(of: context.window) else {
            return .uncertain
        }

        // 原生文件面板有两种形态：独立窗口（AXStandardWindow）与 sheet（AXDialog）。
        // 「前往文件夹」面板也是 AXDialog，但它没有文件列表，会在下面的结构判定中被排除。
        guard subrole == (kAXStandardWindowSubrole as String) || subrole == "AXDialog" else {
            return .uncertain
        }

        // 结构特征：窗口内存在文件列表控件。
        let hasFileList = SmartAXReader.firstDescendant(of: context.window) { element in
            guard let role = SmartAXReader.role(of: element) else {
                return false
            }
            return FocusClassifier.browserRoles.contains(role)
        } != nil

        return hasFileList ? .confirmed : .uncertain
    }

    func navigate(to directory: URL, in context: DialogContext) async throws {
        let outcome = await navigator.navigate(to: directory, in: context)
        if outcome.navigated {
            return
        }
        if let error = outcome.error {
            throw error
        }
    }
}
