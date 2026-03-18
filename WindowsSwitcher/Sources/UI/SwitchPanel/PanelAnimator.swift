import AppKit
import SwiftUI

/// T-047 面板显示/隐藏动画
struct PanelAnimator {

    /// 显示面板：缩放 + 淡入
    static func show(_ window: NSWindow, completion: (() -> Void)? = nil) {
        window.alphaValue = 0
        window.setFrame(scaledFrame(window.frame, scale: 0.92), display: false)
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(window.frame.insetBy(dx: -window.frame.width * 0.04,
                                                             dy: -window.frame.height * 0.04),
                                       display: true)
        } completionHandler: {
            completion?()
        }
    }

    /// 隐藏面板：缩放 + 淡出
    static func hide(_ window: NSWindow, completion: (() -> Void)? = nil) {
        let targetFrame = scaledFrame(window.frame, scale: 0.92)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(targetFrame, display: true)
        } completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
            completion?()
        }
    }

    // MARK: - Helper
    private static func scaledFrame(_ frame: CGRect, scale: CGFloat) -> CGRect {
        let dw = frame.width * (1 - scale)
        let dh = frame.height * (1 - scale)
        return frame.insetBy(dx: dw / 2, dy: dh / 2)
    }
}
