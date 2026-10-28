import Foundation
import AppKit
import SwiftUI

/// 非模态失败提示。
///
/// 使用不抢焦点的浮动面板而不是 `NSAlert`：模态弹窗会打断用户当前操作。
final class FeedbackPresenter {

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var lastWarningMessage: String?
    private var lastWarningShownAt: Date?
    private var lastInfoMessage: String?
    private var lastInfoShownAt: Date?

    /// 相同提示在短窗口内合并，避免连续粘贴时反复弹出。
    private let mergeInterval: TimeInterval = 2.0

    func show(message: String, duration: TimeInterval = 3.0) {
        show(message: message, style: .warning, duration: duration)
    }

    func show(message: String, style: NavigationToastView.Style, duration: TimeInterval = 3.0) {
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(message: message, style: style, duration: duration)
        }
    }

    private func showOnMain(message: String, style: NavigationToastView.Style, duration: TimeInterval) {
        switch style {
        case .warning:
            if let lastWarningMessage, lastWarningMessage == message,
               let lastWarningShownAt, Date().timeIntervalSince(lastWarningShownAt) < mergeInterval {
                return
            }
            lastWarningMessage = message
            lastWarningShownAt = Date()
        case .info:
            if let lastInfoMessage, lastInfoMessage == message,
               let lastInfoShownAt, Date().timeIntervalSince(lastInfoShownAt) < mergeInterval {
                return
            }
            lastInfoMessage = message
            lastInfoShownAt = Date()
        }

        dismissWorkItem?.cancel()

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hosting = NSHostingView(rootView: NavigationToastView(message: message, style: style))
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(260, min(420, fitting.width)),
                                    height: max(46, fitting.height)))
        position(panel)
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                            styleMask: [.nonactivatingPanel, .titled],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar + 1
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// 定位到主屏幕右下角。
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24,
                                     y: visible.minY + 24))
    }
}
