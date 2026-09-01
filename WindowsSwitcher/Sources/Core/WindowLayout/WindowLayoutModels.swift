import CoreGraphics
import Foundation

/// 窗口布局命令。
///
/// 阶段二的 UI、布局服务和 Accessibility 写入层只传递该类型，避免各层分别维护字符串命令。
enum WindowLayoutCommand: Equatable, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case maximize
    case center
    case previousDisplay
    case nextDisplay
}

/// 窗口布局未执行的明确原因。
enum WindowLayoutFailure: Error, Equatable {
    case accessibilityPermissionMissing
    case windowNotFound
    case nonStandardWindow
    case fullScreenWindow
    case positionNotWritable
    case sizeNotWritable
    case targetDisplayUnavailable
    case writeFailed(code: Int)
    case verificationFailed
}

/// 窗口布局执行结果。
enum WindowLayoutResult: Equatable {
    case applied(frame: CGRect, displayID: CGDirectDisplayID)
    case constrained(frame: CGRect, displayID: CGDirectDisplayID)
    case skipped(WindowLayoutFailure)
}

/// Accessibility 写入前的能力探测结果。
struct AccessibilityWindowCapabilities: Equatable {
    let currentFrame: CGRect
    let isFullScreen: Bool
    let canSetPosition: Bool
    let canSetSize: Bool
}

/// Accessibility 写入和回读验证的结果。
enum AccessibilityWindowWriteResult: Equatable {
    /// 实际 frame 在集中配置的误差范围内匹配目标 frame。
    case applied(originalFrame: CGRect, actualFrame: CGRect)
    /// 应用自身最小尺寸等约束调整了结果，但位置有效且窗口仍可用。
    case constrained(originalFrame: CGRect, actualFrame: CGRect)
    /// 能力探测、写入或回读失败。
    case skipped(WindowLayoutFailure)
}

/// 统一到 Accessibility 全局坐标系后的显示器描述。
///
/// `frame` 和 `visibleFrame` 均使用左上角为原点、Y 轴向下的全局逻辑坐标；不包含 Retina 像素倍率。
struct ScreenDescriptor: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let isMain: Bool
}

/// 相邻显示器移动方向。
enum DisplayTraversalDirection: Equatable {
    case previous
    case next
}
