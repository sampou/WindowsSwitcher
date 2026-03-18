import AppKit
import CoreGraphics

enum WindowEvent {
    case windowCreated(WindowModel)
    case windowDestroyed(CGWindowID)
    case windowStateChanged(WindowModel)
}

protocol WindowManagerProtocol {
    func getAllWindows() -> [WindowModel]
    func getWindows(for appName: String) -> [WindowModel]
    func activateWindow(_ window: WindowModel)
    func closeWindow(_ window: WindowModel)
    func minimizeWindow(_ window: WindowModel)
    func hideWindow(_ window: WindowModel)
    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void)
}

class WindowManager: WindowManagerProtocol {
    private var eventHandler: ((WindowEvent) -> Void)?
    private var windowCache: [CGWindowID: WindowModel] = [:]
    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func getAllWindows() -> [WindowModel] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let windows = list.compactMap { buildWindowModel(from: $0) }
        windows.forEach { windowCache[$0.id] = $0 }
        return windows.sorted { $0.lastActiveTime > $1.lastActiveTime }
    }

    func getWindows(for appName: String) -> [WindowModel] {
        getAllWindows().filter { $0.appName == appName }
    }

    func activateWindow(_ window: WindowModel) {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else { return }
        app.activate(options: .activateIgnoringOtherApps)
        let axApp = AXUIElementCreateApplication(window.ownerPID)
        var windowList: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        if let wins = windowList as? [AXUIElement] {
            for win in wins {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                if let title = titleRef as? String, title == window.windowTitle {
                    AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    break
                }
            }
        }
    }

    func closeWindow(_ window: WindowModel) {
        let axApp = AXUIElementCreateApplication(window.ownerPID)
        var windowList: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        if let wins = windowList as? [AXUIElement] {
            for win in wins {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                if let title = titleRef as? String, title == window.windowTitle {
                    var closeButton: CFTypeRef?
                    AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &closeButton)
                    if let btn = closeButton, CFGetTypeID(btn) == AXUIElementGetTypeID() {
                        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
                    }
                    break
                }
            }
        }
    }

    func minimizeWindow(_ window: WindowModel) {
        let axApp = AXUIElementCreateApplication(window.ownerPID)
        var windowList: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        if let wins = windowList as? [AXUIElement] {
            for win in wins {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                if let title = titleRef as? String, title == window.windowTitle {
                    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                    break
                }
            }
        }
    }

    func hideWindow(_ window: WindowModel) {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else { return }
        app.hide()
    }

    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {
        self.eventHandler = handler
        // BUG-003: 先移除旧 observer，防止重复注册
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.getAllWindows().forEach { handler(.windowStateChanged($0)) }
        }
        observers.append(token)
    }

    private func buildWindowModel(from info: [String: Any]) -> WindowModel? {
        guard
            let windowID = info[kCGWindowNumber as String] as? CGWindowID,
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0
        else { return nil }

        let appName = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
        let windowTitle = info[kCGWindowName as String] as? String ?? ""
        let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false

        let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let frame = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        let app = NSRunningApplication(processIdentifier: ownerPID)
        let bundleID = app?.bundleIdentifier ?? ""
        let icon = app?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()

        // BUG-001: 通过 AX API 读取最小化状态，降级方案：isOnScreen=false && layer==0
        let isMinimized = Self.axIsMinimized(pid: ownerPID, windowTitle: windowTitle)
            ?? (!isOnScreen && layer == 0)

        return WindowModel(
            id: windowID,
            appName: appName,
            bundleIdentifier: bundleID,
            windowTitle: windowTitle,
            appIcon: icon,
            frame: frame,
            isMinimized: isMinimized,
            isHidden: app?.isHidden ?? false,
            isOnScreen: isOnScreen,
            lastActiveTime: Date(),
            windowLayer: layer,
            ownerPID: ownerPID
        )
    }

    /// 通过 AX API 查询指定窗口的最小化状态。需要辅助功能权限，失败时返回 nil。
    private static func axIsMinimized(pid: pid_t, windowTitle: String) -> Bool? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let wins = windowList as? [AXUIElement] else { return nil }
        for win in wins {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, title == windowTitle else { continue }
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let minimized = minimizedRef as? Bool else { return nil }
            return minimized
        }
        return nil
    }
}
