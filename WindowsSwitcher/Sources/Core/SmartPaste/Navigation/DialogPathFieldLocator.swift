import Foundation
import ApplicationServices

/// 在文件对话框中定位"可写的路径输入框"。
///
/// 两类形态都支持：
/// 1. **内联路径框**：应用在同一个窗口里直接显示一行可写路径（如 Notepad Next 的
///    「打开」弹窗，按下 ⇧⌘G 后出现在顶部中间），其值预填为当前路径；
/// 2. **独立路径框**：应用弹出「前往文件夹」子面板（原生 NSOpenPanel 的做法），
///    其中的路径输入框初始为空。
///
/// 判定条件（全部满足才命中，避免误写搜索框或文件列表）：
/// 1. 角色是 `AXTextField`；
/// 2. **子角色不是 `AXSearchField`**（搜索框靠这条确定性规则排除，
///    不能只靠"不在中轴上"这种几何巧合——搜索框就在右上角，与中轴只差几十像素）；
/// 3. `AXValue` 可写；
/// 4. 当前值以 `/` 开头；独立路径框允许为空（`allowEmpty`）；
/// 5. 位于窗口顶部区域（顶部 45% 以内）且水平方向靠近中轴。
enum DialogPathFieldLocator {

    /// 查找结果。
    struct Match {
        let element: AXUIElement
        let currentPath: String
    }

    /// 窗口顶部区域占比。
    private static let topAreaRatio: CGFloat = 0.45
    /// 水平方向允许偏离中轴的比例（相对窗口宽度）。
    private static let horizontalTolerance: CGFloat = 0.35

    /// 在窗口中定位路径输入框。
    ///
    /// - Parameter allowEmpty: 是否接受空值。独立路径框初始为空，需要开启；
    ///   内联路径框预填了路径，保持关闭可避免误命中空输入框。
    static func locate(in window: AXUIElement, allowEmpty: Bool = false) -> Match? {
        guard let windowFrame = SmartAXReader.frame(of: window) else {
            return nil
        }

        let element = SmartAXReader.firstDescendant(of: window) { candidate in
            isPathFieldCandidate(candidate, in: windowFrame, allowEmpty: allowEmpty)
        }

        guard let element else {
            return nil
        }

        return Match(element: element, currentPath: SmartAXReader.value(of: element) ?? "")
    }

    /// 判定单个元素是否是路径输入框。拆成纯函数以便单元测试。
    static func isPathFieldCandidate(_ element: AXUIElement,
                                     in windowFrame: CGRect,
                                     allowEmpty: Bool = false) -> Bool {
        guard SmartAXReader.role(of: element) == "AXTextField" else {
            return false
        }
        // 搜索框必须显式排除：它同样是可写的 AXTextField，且位于窗口顶部。
        guard SmartAXReader.subrole(of: element) != "AXSearchField" else {
            return false
        }
        guard SmartAXReader.isSettable(element, kAXValueAttribute as CFString) else {
            return false
        }
        let value = SmartAXReader.value(of: element) ?? ""
        if value.isEmpty {
            guard allowEmpty else { return false }
        } else {
            guard value.hasPrefix("/") else { return false }
        }
        guard let frame = SmartAXReader.frame(of: element) else {
            return false
        }
        return isInTopArea(frame, in: windowFrame) && isNearHorizontalCenter(frame, in: windowFrame)
    }

    /// 是否位于窗口顶部区域。
    static func isInTopArea(_ frame: CGRect, in windowFrame: CGRect) -> Bool {
        let topLimit = windowFrame.minY + windowFrame.height * topAreaRatio
        return frame.midY <= topLimit
    }

    /// 是否靠近窗口水平中轴。
    static func isNearHorizontalCenter(_ frame: CGRect, in windowFrame: CGRect) -> Bool {
        guard windowFrame.width > 0 else { return false }
        let center = windowFrame.midX
        let tolerance = windowFrame.width * horizontalTolerance
        return abs(frame.midX - center) <= tolerance
    }
}
