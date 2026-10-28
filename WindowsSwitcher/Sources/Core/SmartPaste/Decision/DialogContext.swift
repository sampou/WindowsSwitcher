import Foundation
import ApplicationServices

/// 文件对话框类型。
enum DialogKind: Equatable {
    case openFile
    case chooseDirectory
    case saveFile
    case custom
}

/// 适配器识别置信度。
///
/// 只有 `confirmed` 才允许拦截粘贴；`uncertain` 与 `unsupported` 一律放行。
enum AdapterConfidence: Equatable {
    case confirmed
    case uncertain
    case unsupported
}

/// 文件对话框上下文（只读快照）。
struct DialogContext {
    let processID: pid_t
    let bundleID: String
    let window: AXUIElement
    let focusedElement: AXUIElement?
    let kind: DialogKind
}

/// 导航过程中的错误。
enum NavigationError: Error, Equatable {
    case permissionDenied
    case invalidDirectory
    case directoryNotAccessible
    case unsupportedDialog
    case targetFieldNotFound
    case axOperationFailed(Int)
    case keyboardSynthesisFailed
    case timeout
    case focusChanged
    case verificationFailed
}
