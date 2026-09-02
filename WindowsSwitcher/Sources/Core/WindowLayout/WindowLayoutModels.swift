import CoreGraphics
import Foundation

/// 窗口布局命令。
///
/// 阶段二的 UI、布局服务和 Accessibility 写入层只传递该类型，避免各层分别维护字符串命令。
enum WindowLayoutCommand: String, Codable, Equatable, CaseIterable {
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

/// 窗口布局动作的稳定标识符。
///
/// 持久化、全局快捷键注册和菜单路由统一使用该标识，避免显示名称变化破坏用户配置。
enum WindowLayoutActionID: String, Codable, CaseIterable, Hashable {
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

/// 可供面板、设置页和状态栏菜单共同消费的窗口布局动作描述。
struct WindowLayoutActionDescriptor: Identifiable, Equatable {
    let id: WindowLayoutActionID
    let command: WindowLayoutCommand
    let title: String
    let symbolName: String
}

/// 窗口布局动作的唯一目录。
enum WindowLayoutActionCatalog {
    static let actions: [WindowLayoutActionDescriptor] = [
        .init(id: .leftHalf, command: .leftHalf, title: "左半屏", symbolName: "rectangle.lefthalf.inset.filled"),
        .init(id: .rightHalf, command: .rightHalf, title: "右半屏", symbolName: "rectangle.righthalf.inset.filled"),
        .init(id: .topHalf, command: .topHalf, title: "上半屏", symbolName: "rectangle.tophalf.inset.filled"),
        .init(id: .bottomHalf, command: .bottomHalf, title: "下半屏", symbolName: "rectangle.bottomhalf.inset.filled"),
        .init(id: .topLeftQuarter, command: .topLeftQuarter, title: "左上角", symbolName: "arrow.up.left.square.fill"),
        .init(id: .topRightQuarter, command: .topRightQuarter, title: "右上角", symbolName: "arrow.up.right.square.fill"),
        .init(id: .bottomLeftQuarter, command: .bottomLeftQuarter, title: "左下角", symbolName: "arrow.down.left.square.fill"),
        .init(id: .bottomRightQuarter, command: .bottomRightQuarter, title: "右下角", symbolName: "arrow.down.right.square.fill"),
        .init(id: .maximize, command: .maximize, title: "最大化", symbolName: "rectangle.inset.filled"),
        .init(id: .center, command: .center, title: "居中", symbolName: "rectangle.center.inset.filled"),
        .init(id: .previousDisplay, command: .previousDisplay, title: "上一显示器", symbolName: "arrow.left.to.line"),
        .init(id: .nextDisplay, command: .nextDisplay, title: "下一显示器", symbolName: "arrow.right.to.line")
    ]

    /// 根据稳定标识符查找动作。
    static func action(for id: WindowLayoutActionID) -> WindowLayoutActionDescriptor? {
        actions.first { $0.id == id }
    }
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
