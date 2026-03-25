import Foundation
import AppKit
import ApplicationServices

// MARK: - DockEventMonitor
/// 程序坞图标事件监听器
class DockEventMonitor: ObservableObject {
    @Published var hoveredAppBundleID: String?
    @Published var isDockVisible: Bool = true
    @Published var dockPosition: DockPosition = .bottom

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hoverTimer: Timer?

    /// 悬停延迟（从配置读取，默认 350ms）
    private var hoverDelay: TimeInterval {
        ConfigManager.shared.config.dockPreview.hoverDelay
    }

    init() {
        setupDockMonitoring()
        checkAccessibilityPermission()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    // 使用 NSEvent 全局监听（更简单可靠）
    private var globalMouseMonitor: Any?

    func startMonitoring() {
        guard globalMouseMonitor == nil else { return }

        // 检查辅助功能权限
        let hasAccessibility = AXIsProcessTrusted()
        Logger.info("DockEventMonitor start - Accessibility: \(hasAccessibility)")

        // 使用 NSEvent 全局监听鼠标移动
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved(event)
        }

        if globalMouseMonitor != nil {
            Logger.info("DockEventMonitor started successfully")
        } else {
            Logger.warning("Failed to create mouse monitor")
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        let dockFrame = getDockFrame()

        Logger.debug("Mouse at: \(location), dock: \(dockFrame)")

        // 检查鼠标是否在 Dock 区域
        let isInDockArea = dockFrame.insetBy(dx: -20, dy: -20).contains(location)

        if isInDockArea {
            Logger.debug("In dock area, checking app...")
            if let appBundleID = getAppBundleIDAtScreenLocation(location) {
                Logger.debug("App found: \(appBundleID)")
                startHoverTimer(for: appBundleID)
            }
        } else {
            cancelHoverTimer()
        }
    }

    // 转换屏幕坐标
    private func getAppBundleIDAtScreenLocation(_ location: CGPoint) -> String? {
        guard let screen = NSScreen.main else { return nil }

        // 转换坐标（macOS 坐标系统不同）
        let y = screen.frame.height - location.y

        let systemWideElement = AXUIElementCreateSystemWide()

        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(location.x),
            Float(y),
            &element
        )

        guard result == .success, let axElement = element else {
            return nil
        }

        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }

        return app.bundleIdentifier
    }

    func stopMonitoring() {
        // 清理全局监听器
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }

        // 清理旧的 CGEvent tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        hoverTimer?.invalidate()
        hoverTimer = nil

        Logger.info("DockEventMonitor stopped")
    }

    // MARK: - Private Methods

    private func setupDockMonitoring() {
        // 检测 Dock 位置
        updateDockPosition()
    }

    @objc private func dockDidShow() {
        isDockVisible = true
    }

    private func updateDockPosition() {
        // 从系统偏好设置获取 Dock 位置
        if let dockPlist = UserDefaults(suiteName: "com.apple.dock")?.dictionaryRepresentation() {
            let position = dockPlist["orientation"] as? String ?? "bottom"
            switch position {
            case "top":
                dockPosition = .top
            case "left":
                dockPosition = .left
            case "right":
                dockPosition = .right
            default:
                dockPosition = .bottom
            }
        }
    }

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            Logger.warning("Accessibility permission not granted")
            requestAccessibilityPermission()
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func startHoverTimer(for bundleID: String) {
        hoverTimer?.invalidate()

        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hoveredAppBundleID = bundleID
                Logger.debug("Dock hover detected: \(bundleID)")
            }
        }
    }

    private func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil

        if hoveredAppBundleID != nil {
            DispatchQueue.main.async { [weak self] in
                self?.hoveredAppBundleID = nil
            }
        }
    }

    private func getDockFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 800, height: 80)
        }

        let screenFrame = screen.frame

        // 从系统获取 Dock 尺寸
        let dockSize = getDockSize()

        switch dockPosition {
        case .bottom:
            return CGRect(
                x: 0,
                y: 0,
                width: screenFrame.width,
                height: dockSize
            )
        case .top:
            return CGRect(
                x: 0,
                y: screenFrame.height - dockSize,
                width: screenFrame.width,
                height: dockSize
            )
        case .left:
            return CGRect(
                x: 0,
                y: 0,
                width: dockSize,
                height: screenFrame.height
            )
        case .right:
            return CGRect(
                x: screenFrame.width - dockSize,
                y: 0,
                width: dockSize,
                height: screenFrame.height
            )
        }
    }

    private func getDockSize() -> CGFloat {
        // 从系统获取 Dock 尺寸
        if let size = UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "size") {
            return CGFloat(size) + 80 // 基础高度 + 图标尺寸
        }
        return 80 // 默认值
    }

    private func getAppBundleIDAtLocation(_ location: CGPoint) -> String? {
        // 使用 AXUIElement 获取鼠标位置的应用
        let systemWideElement = AXUIElementCreateSystemWide()

        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(location.x),
            Float(NSScreen.main!.frame.height - location.y),
            &element
        )

        guard result == .success, let axElement = element else {
            return nil
        }

        // 获取应用 PID
        var pid: pid_t = 0
        AXUIElementGetPid(axElement, &pid)

        // 获取应用 Bundle ID
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }

        return app.bundleIdentifier
    }
}

