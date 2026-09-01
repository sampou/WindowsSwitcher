import ApplicationServices
import CoreGraphics
import Foundation

/// Accessibility 窗口写入配置。
struct AccessibilityWindowWriterConfiguration: Equatable {
    /// 目标与回读 frame 每个分量允许的逻辑点误差。
    let verificationTolerance: CGFloat
    /// 应用约束结果允许的位置偏差；尺寸可由应用最小尺寸约束扩大。
    let constrainedPositionTolerance: CGFloat

    static let `default` = AccessibilityWindowWriterConfiguration(
        verificationTolerance: 2,
        constrainedPositionTolerance: 8
    )
}

/// 串行执行能力探测、位置/尺寸写入和回读验证。
final class AccessibilityWindowWriter {
    private let backend: any AccessibilityWindowAccessing
    private let configuration: AccessibilityWindowWriterConfiguration
    private let executionLock = NSLock()

    init(
        backend: any AccessibilityWindowAccessing = SystemAccessibilityWindowBackend(),
        configuration: AccessibilityWindowWriterConfiguration = .default
    ) {
        self.backend = backend
        self.configuration = configuration
    }

    /// 探测目标窗口是否可执行布局命令。
    func probe(_ model: WindowModel) -> Result<AccessibilityWindowCapabilities, WindowLayoutFailure> {
        executionLock.lock()
        defer { executionLock.unlock() }
        return validatedWindow(for: model).map(\.capabilities)
    }

    /// 写入目标 frame，并通过回读区分精确成功、应用约束和失败。
    func apply(targetFrame: CGRect, to model: WindowModel) -> AccessibilityWindowWriteResult {
        executionLock.lock()
        defer { executionLock.unlock() }

        let validated: ValidatedWindow
        switch validatedWindow(for: model) {
        case .success(let value):
            validated = value
        case .failure(let failure):
            return .skipped(failure)
        }

        let target = targetFrame.standardized
        guard target.isFiniteLayoutFrame else {
            return .skipped(.verificationFailed)
        }

        let firstPositionResult = backend.setPosition(target.origin, for: validated.reference)
        guard firstPositionResult == .success else {
            return .skipped(failure(for: firstPositionResult))
        }

        let sizeResult = backend.setSize(target.size, for: validated.reference)
        guard sizeResult == .success else {
            // 位置已经改变但尺寸未改变；尽力恢复原始位置，避免留下部分布局状态。
            _ = backend.setPosition(validated.capabilities.currentFrame.origin, for: validated.reference)
            return .skipped(failure(for: sizeResult))
        }

        let secondPositionResult = backend.setPosition(target.origin, for: validated.reference)
        guard secondPositionResult == .success else {
            rollback(validated.capabilities.currentFrame, reference: validated.reference)
            return .skipped(failure(for: secondPositionResult))
        }

        guard let actualFrame = backend.frame(of: validated.reference)?.standardized,
              actualFrame.isFiniteLayoutFrame else {
            return .skipped(.verificationFailed)
        }

        let originalFrame = validated.capabilities.currentFrame
        if actualFrame.isApproximatelyEqual(
            to: target,
            tolerance: configuration.verificationTolerance
        ) {
            return .applied(originalFrame: originalFrame, actualFrame: actualFrame)
        }

        if actualFrame.hasApproximatelyEqualPosition(
            to: target,
            tolerance: configuration.constrainedPositionTolerance
        ), actualFrame.width > 0, actualFrame.height > 0 {
            return .constrained(originalFrame: originalFrame, actualFrame: actualFrame)
        }

        return .skipped(.verificationFailed)
    }

    private func validatedWindow(for model: WindowModel) -> Result<ValidatedWindow, WindowLayoutFailure> {
        guard backend.isProcessTrusted() else {
            return .failure(.accessibilityPermissionMissing)
        }
        guard model.isStandardWindow else {
            return .failure(.nonStandardWindow)
        }
        guard let reference = backend.resolveWindow(for: model) else {
            return .failure(.windowNotFound)
        }
        guard backend.isStandardWindow(reference) else {
            return .failure(.nonStandardWindow)
        }
        guard !backend.isFullScreen(reference) else {
            return .failure(.fullScreenWindow)
        }
        guard backend.isSettable(.position, for: reference) else {
            return .failure(.positionNotWritable)
        }
        guard backend.isSettable(.size, for: reference) else {
            return .failure(.sizeNotWritable)
        }
        guard let currentFrame = backend.frame(of: reference)?.standardized,
              currentFrame.isFiniteLayoutFrame else {
            return .failure(.verificationFailed)
        }

        let capabilities = AccessibilityWindowCapabilities(
            currentFrame: currentFrame,
            isFullScreen: false,
            canSetPosition: true,
            canSetSize: true
        )
        return .success(ValidatedWindow(reference: reference, capabilities: capabilities))
    }

    private func failure(for error: AXError) -> WindowLayoutFailure {
        if error == .invalidUIElement {
            return .windowNotFound
        }
        return .writeFailed(code: Int(error.rawValue))
    }

    private func rollback(_ frame: CGRect, reference: AccessibilityWindowReference) {
        _ = backend.setSize(frame.size, for: reference)
        _ = backend.setPosition(frame.origin, for: reference)
    }
}

private struct ValidatedWindow {
    let reference: AccessibilityWindowReference
    let capabilities: AccessibilityWindowCapabilities
}

private extension CGRect {
    var isFiniteLayoutFrame: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        hasApproximatelyEqualPosition(to: other, tolerance: tolerance)
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    func hasApproximatelyEqualPosition(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
    }
}
