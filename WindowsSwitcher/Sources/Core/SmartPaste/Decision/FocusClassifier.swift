import Foundation
import ApplicationServices

/// 焦点分类。
///
/// 决策依据：焦点在**任何文本输入控件**（含文件面板的文件名输入框、搜索框）时，
/// ⌘V 一律按原生「值粘贴」处理，不做目录跳转。
/// 只有焦点落在文件列表或面板非文本控件时，才可能触发智能跳转。
enum FocusClassification: Equatable {
    /// 文本控件（含文件名输入框）→ 放行
    case textInput
    /// 文件浏览区域（文件列表）→ 可导航
    case fileBrowser
    /// 文件面板的非文本控件 → 可导航
    case dialogControl
    /// 无法识别 → 放行（不得等同非文本）
    case unknown
}

/// 焦点控件分类器。
enum FocusClassifier {

    /// 文本类角色：命中即放行，不区分文件名框与其他文本框。
    static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField"
    ]

    /// 文件列表类角色。
    static let browserRoles: Set<String> = [
        "AXTable",
        "AXOutline",
        "AXBrowser"
    ]

    /// 面板内可交互但非文本的角色。
    static let dialogControlRoles: Set<String> = [
        "AXButton",
        "AXCell",
        "AXRow"
    ]

    /// 按 AX 角色分类，供纯逻辑测试使用。
    static func classify(role: String?) -> FocusClassification {
        guard let role, !role.isEmpty else {
            return .unknown
        }
        if textRoles.contains(role) {
            return .textInput
        }
        if browserRoles.contains(role) {
            return .fileBrowser
        }
        if dialogControlRoles.contains(role) {
            return .dialogControl
        }
        return .unknown
    }

    /// 按实际 AX 元素分类。
    static func classify(element: AXUIElement?) -> FocusClassification {
        guard let element else {
            return .unknown
        }
        return classify(role: SmartAXReader.role(of: element))
    }
}
