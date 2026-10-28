import Foundation

/// 放行原始 ⌘V 的原因。用于诊断日志，不向用户暴露。
enum PassThroughReason: String, Equatable {
    case featureDisabled
    case clipboardNotPath
    case clipboardIsFile
    case clipboardMissing
    case focusIsTextInput
    case focusUnknown
    case unsupportedDialog
    case noAdapter
    case selfApplication
    case panelVisible
    case snapshotExpired
    case foregroundChanged
    case clipboardChanged
    case focusChanged
}

/// 粘贴决策结果。
///
/// 引擎只回答「是否应当拦截」，不负责构造导航请求，
/// 这样决策逻辑可以保持纯函数并被完整单测。
enum PasteDecision: Equatable {
    case allow
    case deny(PassThroughReason)
}

/// 粘贴决策引擎。
///
/// 纯逻辑实现，不接触 AX / 剪贴板 / 文件系统，便于单元测试。
struct PasteDecisionEngine {

    struct Input: Equatable {
        let clipboard: ClipboardPathResult
        let focus: FocusClassification
        let adapterConfidence: AdapterConfidence?
    }

    /// 判定本次 ⌘V 是否应当被拦截。
    ///
    /// 全部满足才允许拦截：剪贴板是目录、焦点不在文本控件、适配器明确确认支持。
    /// 其余情况一律放行（fail-open）。
    func decide(_ input: Input) -> PasteDecision {
        switch input.clipboard {
        case .directory:
            break
        case .file:
            return .deny(.clipboardIsFile)
        case .missing:
            return .deny(.clipboardMissing)
        case .notApplicable:
            return .deny(.clipboardNotPath)
        }

        switch input.focus {
        case .textInput:
            return .deny(.focusIsTextInput)
        case .unknown:
            return .deny(.focusUnknown)
        case .fileBrowser, .dialogControl:
            break
        }

        guard input.adapterConfidence == .confirmed else {
            return .deny(.unsupportedDialog)
        }

        return .allow
    }
}
