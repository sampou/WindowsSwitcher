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

    func startMonitoring() {
        guard eventTap == nil else { return }

        // 检查辅助功能权限
        let hasAccessibility = AXIsProcessTrusted()
        Logger.info("DockEventMonitor start - Accessibility permission: \(hasAccessibility)")

        guard hasAccessibility else {
            Logger.warning("Cannot start DockEventMonitor - accessibility permission required")
            return
        }

        // 创建事件tap - 只监听 mouseMoved
        let eventMask = (1 << CGEventType.mouseMoved.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }
                let monitor = Unmanaged<DockEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleEvent(proxy: proxy, type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.warning("Failed to create event tap - accessibility permission may be required")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Logger.info("DockEventMonitor started successfully")
        }
    }

    func stopMonitoring() {
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

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        guard type == .mouseMoved else {
            return
        }

        let location = event.location
        let dockFrame = getDockFrame()

        Logger.debug("Mouse moved to: \(location), dockFrame: \(dockFrame)")

        // 检查鼠标是否在 Dock 区域
        let isInDockArea = dockFrame.insetBy(dx: -20, dy: -20).contains(location)

        if isInDockArea {
            Logger.debug("Mouse is in dock area")
            // 获取鼠标下的应用
            if let appBundleID = getAppBundleIDAtLocation(location) {
                Logger.debug("App bundle ID at location: \(appBundleID)")
                startHoverTimer(for: appBundleID)
            }
        } else {
            cancelHoverTimer()
        }
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

