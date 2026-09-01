import CoreGraphics
import Foundation

/// 窗口布局服务协议。
protocol WindowLayoutServicing {
    /// 对指定窗口执行一个布局命令。
    func execute(_ command: WindowLayoutCommand, for window: WindowModel) -> WindowLayoutResult
}

/// 窗口布局执行日志。
protocol WindowLayoutLogging {
    func record(
        command: WindowLayoutCommand,
        windowID: CGWindowID,
        result: WindowLayoutResult,
        repeated: Bool
    )
}

/// 默认布局日志实现，复用现有用户操作日志。
struct SystemWindowLayoutLogger: WindowLayoutLogging {
    func record(
        command: WindowLayoutCommand,
        windowID: CGWindowID,
        result: WindowLayoutResult,
        repeated: Bool
    ) {
        Logger.operation(
            "窗口布局",
            detail: "命令=\(command.logName), 窗口ID=\(windowID), 重复=\(repeated)",
            result: result.logDescription
        )
    }
}

/// 窗口布局编排服务。
///
/// 服务每次执行时重新创建屏幕解析快照，串行组合能力探测、当前/目标屏幕解析、
/// 纯几何计算和 AX 写入。它不持有 `WindowManager` 缓存锁，也不修改窗口排序状态。
final class WindowLayoutService: WindowLayoutServicing {
    private let calculator: any WindowLayoutCalculating
    private let writer: any AccessibilityWindowWriting
    private let screenResolverProvider: () -> any ScreenResolving
    private let logger: any WindowLayoutLogging
    private let executionLock = NSLock()
    private let repeatedCommandTolerance: CGFloat

    init(
        calculator: any WindowLayoutCalculating = WindowLayoutCalculator(),
        writer: any AccessibilityWindowWriting = AccessibilityWindowWriter(),
        screenResolverProvider: @escaping () -> any ScreenResolving = { ScreenResolver() },
        logger: any WindowLayoutLogging = SystemWindowLayoutLogger(),
        repeatedCommandTolerance: CGFloat = 2
    ) {
        self.calculator = calculator
        self.writer = writer
        self.screenResolverProvider = screenResolverProvider
        self.logger = logger
        self.repeatedCommandTolerance = max(0, repeatedCommandTolerance)
    }

    func execute(_ command: WindowLayoutCommand, for window: WindowModel) -> WindowLayoutResult {
        executionLock.lock()
        defer { executionLock.unlock() }

        let capabilities: AccessibilityWindowCapabilities
        switch writer.probe(window) {
        case .success(let value):
            capabilities = value
        case .failure(let failure):
            return finish(command, windowID: window.id, result: .skipped(failure))
        }

        let resolver = screenResolverProvider()
        guard let sourceScreen = resolver.currentScreen(for: capabilities.currentFrame) else {
            return finish(
                command,
                windowID: window.id,
                result: .skipped(.targetDisplayUnavailable)
            )
        }

        let target: (screen: ScreenDescriptor, frame: CGRect)
        switch command {
        case .previousDisplay, .nextDisplay:
            let direction: DisplayTraversalDirection = command == .previousDisplay ? .previous : .next
            guard let targetScreen = resolver.adjacentScreen(from: sourceScreen.id, direction: direction) else {
                return finish(
                    command,
                    windowID: window.id,
                    result: .skipped(.targetDisplayUnavailable)
                )
            }
            target = (
                targetScreen,
                calculator.targetFrameForDisplayMove(
                    currentFrame: capabilities.currentFrame,
                    sourceVisibleFrame: sourceScreen.visibleFrame,
                    targetVisibleFrame: targetScreen.visibleFrame
                )
            )
        default:
            target = (
                sourceScreen,
                calculator.targetFrame(
                    for: command,
                    currentFrame: capabilities.currentFrame,
                    visibleFrame: sourceScreen.visibleFrame
                )
            )
        }

        guard target.frame.isValidWindowLayoutFrame else {
            return finish(
                command,
                windowID: window.id,
                result: .skipped(.targetDisplayUnavailable)
            )
        }

        if capabilities.currentFrame.isApproximatelyEqual(
            to: target.frame,
            tolerance: repeatedCommandTolerance
        ) {
            return finish(
                command,
                windowID: window.id,
                result: .applied(frame: capabilities.currentFrame, displayID: target.screen.id),
                repeated: true
            )
        }

        let result: WindowLayoutResult
        switch writer.apply(targetFrame: target.frame, to: window) {
        case .applied(_, let actualFrame):
            result = .applied(frame: actualFrame, displayID: target.screen.id)
        case .constrained(_, let actualFrame):
            result = .constrained(frame: actualFrame, displayID: target.screen.id)
        case .skipped(let failure):
            result = .skipped(failure)
        }
        return finish(command, windowID: window.id, result: result)
    }

    private func finish(
        _ command: WindowLayoutCommand,
        windowID: CGWindowID,
        result: WindowLayoutResult,
        repeated: Bool = false
    ) -> WindowLayoutResult {
        logger.record(command: command, windowID: windowID, result: result, repeated: repeated)
        return result
    }
}

private extension WindowLayoutCommand {
    var logName: String {
        switch self {
        case .leftHalf: return "leftHalf"
        case .rightHalf: return "rightHalf"
        case .topHalf: return "topHalf"
        case .bottomHalf: return "bottomHalf"
        case .topLeftQuarter: return "topLeftQuarter"
        case .topRightQuarter: return "topRightQuarter"
        case .bottomLeftQuarter: return "bottomLeftQuarter"
        case .bottomRightQuarter: return "bottomRightQuarter"
        case .maximize: return "maximize"
        case .center: return "center"
        case .previousDisplay: return "previousDisplay"
        case .nextDisplay: return "nextDisplay"
        }
    }
}

private extension WindowLayoutResult {
    var logDescription: String {
        switch self {
        case .applied(let frame, let displayID):
            return "applied, displayID=\(displayID), frame=\(frame)"
        case .constrained(let frame, let displayID):
            return "constrained, displayID=\(displayID), frame=\(frame)"
        case .skipped(let failure):
            return "skipped, failure=\(failure)"
        }
    }
}

private extension CGRect {
    var isValidWindowLayoutFrame: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
