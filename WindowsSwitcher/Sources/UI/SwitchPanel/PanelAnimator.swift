import AppKit
import SwiftUI

/// T-047 面板显示/隐藏动画 - 简化版本，提升性能
struct PanelAnimator {

    /// 显示面板：简化为只有淡入
    static func show(_ window: NSWindow, completion: (() -> Void)? = nil) {
        window.alphaValue = 0
        window.orderFrontRegardless()  // 先显示窗口

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1  // 缩短动画时间
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        } completionHandler: {
            // 动画完成后确保窗口成为 key window，这样才能接收键盘事件
            window.makeKey()  // 关键：让面板成为 key window
            completion?()
        }
    }

    /// 隐藏面板：简化为只有淡出
    static func hide(_ window: NSWindow, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08  // 缩短动画时间
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
            completion?()
        }
    }
}
