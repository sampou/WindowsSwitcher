import CoreGraphics
import Foundation

/// 窗口布局几何计算协议。
protocol WindowLayoutCalculating {
    /// 计算单屏布局命令的目标窗口矩形。
    func targetFrame(
        for command: WindowLayoutCommand,
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect

    /// 计算跨显示器移动的目标窗口矩形。
    func targetFrameForDisplayMove(
        currentFrame: CGRect,
        sourceVisibleFrame: CGRect,
        targetVisibleFrame: CGRect
    ) -> CGRect
}

/// 纯函数窗口布局几何计算器。
///
/// 输入和输出均为 Accessibility 全局逻辑坐标。相邻预设共用同一条取整边界：奇数尺寸的余量分配给右侧或下侧，
/// 因而不会产生缝隙或越过 `visibleFrame`。
struct WindowLayoutCalculator: WindowLayoutCalculating {
    func targetFrame(
        for command: WindowLayoutCommand,
        currentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let visible = normalizedVisibleFrame(visibleFrame)
        guard visible.width > 0, visible.height > 0 else { return .zero }

        let splitX = visible.minX + floor(visible.width / 2)
        let splitY = visible.minY + floor(visible.height / 2)

        switch command {
        case .leftHalf:
            return CGRect(
                x: visible.minX,
                y: visible.minY,
                width: splitX - visible.minX,
                height: visible.height
            )
        case .rightHalf:
            return CGRect(
                x: splitX,
                y: visible.minY,
                width: visible.maxX - splitX,
                height: visible.height
            )
        case .topHalf:
            return CGRect(
                x: visible.minX,
                y: visible.minY,
                width: visible.width,
                height: splitY - visible.minY
            )
        case .bottomHalf:
            return CGRect(
                x: visible.minX,
                y: splitY,
                width: visible.width,
                height: visible.maxY - splitY
            )
        case .topLeftQuarter:
            return CGRect(
                x: visible.minX,
                y: visible.minY,
                width: splitX - visible.minX,
                height: splitY - visible.minY
            )
        case .topRightQuarter:
            return CGRect(
                x: splitX,
                y: visible.minY,
                width: visible.maxX - splitX,
                height: splitY - visible.minY
            )
        case .bottomLeftQuarter:
            return CGRect(
                x: visible.minX,
                y: splitY,
                width: splitX - visible.minX,
                height: visible.maxY - splitY
            )
        case .bottomRightQuarter:
            return CGRect(
                x: splitX,
                y: splitY,
                width: visible.maxX - splitX,
                height: visible.maxY - splitY
            )
        case .maximize:
            return visible
        case .center:
            return centeredFrame(currentFrame, in: visible)
        case .previousDisplay, .nextDisplay:
            // 跨屏命令需要源屏幕信息；服务层应调用 targetFrameForDisplayMove。
            // 此处仍返回安全的屏内结果，避免误用时把窗口放到可用区域之外。
            return fittedFrame(currentFrame, in: visible)
        }
    }

    func targetFrameForDisplayMove(
        currentFrame: CGRect,
        sourceVisibleFrame: CGRect,
        targetVisibleFrame: CGRect
    ) -> CGRect {
        let source = normalizedVisibleFrame(sourceVisibleFrame)
        let target = normalizedVisibleFrame(targetVisibleFrame)
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else {
            return .zero
        }

        let current = currentFrame.standardized
        let relativeCenterX = clampedUnit((current.midX - source.minX) / source.width)
        let relativeCenterY = clampedUnit((current.midY - source.minY) / source.height)
        let targetCenter = CGPoint(
            x: target.minX + relativeCenterX * target.width,
            y: target.minY + relativeCenterY * target.height
        )

        let sourceSize = CGSize(width: max(0, current.width), height: max(0, current.height))
        let fittedSize = proportionallyFittedSize(sourceSize, in: target.size)
        let proposed = CGRect(
            x: targetCenter.x - fittedSize.width / 2,
            y: targetCenter.y - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        return clampedFrame(proposed, in: target)
    }

    private func normalizedVisibleFrame(_ frame: CGRect) -> CGRect {
        let frame = frame.standardized
        let minX = frame.minX.rounded()
        let minY = frame.minY.rounded()
        let maxX = frame.maxX.rounded()
        let maxY = frame.maxY.rounded()
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private func centeredFrame(_ currentFrame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let current = currentFrame.standardized
        let size = CGSize(
            width: min(max(0, current.width), visibleFrame.width),
            height: min(max(0, current.height), visibleFrame.height)
        )
        let proposed = CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return clampedFrame(proposed, in: visibleFrame)
    }

    private func fittedFrame(_ currentFrame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let current = currentFrame.standardized
        let size = proportionallyFittedSize(current.size, in: visibleFrame.size)
        let proposed = CGRect(origin: current.origin, size: size)
        return clampedFrame(proposed, in: visibleFrame)
    }

    private func proportionallyFittedSize(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(1, min(bounds.width / size.width, bounds.height / size.height))
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    private func clampedFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        let width = min(max(0, frame.width.rounded()), bounds.width)
        let height = min(max(0, frame.height.rounded()), bounds.height)
        let maxOriginX = bounds.maxX - width
        let maxOriginY = bounds.maxY - height
        let x = min(max(frame.origin.x.rounded(), bounds.minX), maxOriginX)
        let y = min(max(frame.origin.y.rounded(), bounds.minY), maxOriginY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func clampedUnit(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
