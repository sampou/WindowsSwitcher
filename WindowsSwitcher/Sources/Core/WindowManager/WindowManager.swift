import AppKit
import CoreGraphics

// 私有 API：通过 AXUIElement 获取对应的 CGWindowID
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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
    // 单例实例
    static let shared = WindowManager()

    private var eventHandler: ((WindowEvent) -> Void)?
    private var windowCache: [CGWindowID: WindowModel] = [:]
    private var observers: [NSObjectProtocol] = []

    // 窗口列表缓存（避免频繁调用 CGWindowListCopyWindowInfo）
    private var cachedWindows: [WindowModel] = []
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 0.1 // 100ms 缓存

    private init() {}

    // 缓存的窗口列表
    var windows: [WindowModel] {
        getAllWindows()
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func getAllWindows() -> [WindowModel] {
        // 使用缓存，避免频繁调用
        let now = Date()
        if let timestamp = cacheTimestamp,
           now.timeIntervalSince(timestamp) < cacheTTL,
           !cachedWindows.isEmpty {
            return cachedWindows
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let windows = list.compactMap { buildWindowModel(from: $0) }
        windows.forEach { windowCache[$0.id] = $0 }

        // 更新缓存
        cachedWindows = windows
        cacheTimestamp = now

        // 按最后活跃时间排序
        return windows.sorted { $0.lastActiveTime > $1.lastActiveTime }
    }

    /// 强制刷新窗口缓存
    func refreshCache() {
        cacheTimestamp = nil
    }

    func getWindows(for appName: String) -> [WindowModel] {
        getAllWindows().filter { $0.appName == appName }
    }

    func activateWindow(_ window: WindowModel) {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
            Logger.error("Failed to get NSRunningApplication for PID: \(window.ownerPID)")
            return
        }

        // 快速激活应用（核心方法）
        let activateResult = app.activate(options: .activateIgnoringOtherApps)
        if !activateResult {
            Logger.warning("NSRunningApplication.activate returned false")
        }

        // 更新窗口的 lastActiveTime 为当前时间，确保排序正确
        let now = Date()
        if var cachedWindow = windowCache[window.id] {
            cachedWindow = WindowModel(
                id: cachedWindow.id,
                appName: cachedWindow.appName,
                bundleIdentifier: cachedWindow.bundleIdentifier,
                windowTitle: cachedWindow.windowTitle,
                appIcon: cachedWindow.appIcon,
                frame: cachedWindow.frame,
                isMinimized: cachedWindow.isMinimized,
                isHidden: cachedWindow.isHidden,
                isOnScreen: cachedWindow.isOnScreen,
                lastActiveTime: now,
                windowLayer: cachedWindow.windowLayer,
                ownerPID: cachedWindow.ownerPID
            )
            windowCache[window.id] = cachedWindow
            // 同时更新缓存的窗口列表
            cachedWindows = cachedWindows.map { $0.id == window.id ? cachedWindow : $0 }
        }

        // 简化窗口激活：只做必要操作，减少延迟
        // 直接 raise 窗口，跳过不必要的 AX API 调用
        DispatchQueue.main.async { [weak self] in
            if let win = self?.axWindow(for: window) {
                // 设置焦点（异步执行，不阻塞）
                AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                // raise 窗口
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            }
        }

        Logger.info("Activated window: \(window.appName) - \(window.windowTitle)")
    }

    func closeWindow(_ window: WindowModel) {
        guard let win = axWindow(for: window) else { return }
        var closeButton: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &closeButton)
        if let btn = closeButton, CFGetTypeID(btn) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }

    func minimizeWindow(_ window: WindowModel) {
        guard let win = axWindow(for: window) else { return }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
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
        ) { [weak self] notification in
            guard let self else { return }
            // BUG-011: 更新被激活应用的所有窗口的 lastActiveTime
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let now = Date()
                for (id, model) in self.windowCache where model.ownerPID == app.processIdentifier {
                    // 重建 WindowModel 更新时间戳
                    let updated = WindowModel(
                        id: model.id, appName: model.appName,
                        bundleIdentifier: model.bundleIdentifier,
                        windowTitle: model.windowTitle, appIcon: model.appIcon,
                        frame: model.frame, isMinimized: model.isMinimized,
                        isHidden: model.isHidden, isOnScreen: model.isOnScreen,
                        lastActiveTime: now, windowLayer: model.windowLayer,
                        ownerPID: model.ownerPID
                    )
                    self.windowCache[id] = updated
                    handler(.windowStateChanged(updated))
                }
            }
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

        // BUG-011: lastActiveTime 始终为 Date()，无法反映真实 LRU 顺序
        // 改用 windowCache 中已有的时间戳，首次出现时才用 Date()
        let lastActive = windowCache[windowID]?.lastActiveTime ?? Date()

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
            lastActiveTime: lastActive,
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

    /// BUG-002: 用 CGWindowID 匹配 AXUIElement，比标题匹配更可靠
    private func axWindow(for model: WindowModel) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(model.ownerPID)
        var windowList: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        guard result == .success, let wins = windowList as? [AXUIElement] else {
            Logger.warning("AXUIElementCopyAttributeValue failed for PID \(model.ownerPID): \(result.rawValue)")
            return nil
        }

        if wins.isEmpty {
            Logger.warning("No windows found for \(model.appName) (PID: \(model.ownerPID))")
            return nil
        }

        for win in wins {
            // 通过 _AXUIElementGetWindow 获取 CGWindowID（私有 API，降级用标题匹配）
            var cgWinID: CGWindowID = 0
            if _AXUIElementGetWindow(win, &cgWinID) == .success, cgWinID == model.id {
                Logger.debug("Matched window by CGWindowID: \(cgWinID)")
                return win
            }

            // 降级：标题匹配
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title == model.windowTitle {
                Logger.debug("Matched window by title: \(title)")
                return win
            }
        }

        // 如果都匹配不到，返回第一个窗口作为最后降级方案
        if let firstWin = wins.first {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(firstWin, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? "unknown"
            Logger.warning("Fallback to first window: \(title) for target: \(model.windowTitle)")
            return firstWin
        }

        return nil
    }
}
