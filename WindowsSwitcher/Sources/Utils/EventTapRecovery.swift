import CoreGraphics

/// 事件 tap 被系统禁用时的恢复策略。
///
/// macOS 会在事件 tap 回调超时，或用户输入触发安全机制时禁用该 tap。
/// 禁用之后 tap 不再收到任何事件，功能会**静默失效**，
/// 因此必须显式重新启用，并把禁用次数记录下来用于诊断。
enum EventTapRecovery {

    enum Action: Equatable {
        /// 无需处理，事件正常传递。
        case none
        /// 需要重新启用 tap。
        case reenable
    }

    /// 根据回调事件类型判断是否需要恢复。
    static func action(for type: CGEventType) -> Action {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .reenable
        default:
            return .none
        }
    }

    /// 重新启用事件 tap。
    @discardableResult
    static func reenable(_ tap: CFMachPort?) -> Bool {
        guard let tap else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}
