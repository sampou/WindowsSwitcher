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
    private let cacheTTL: TimeInterval = 0.3 // 300ms 缓存，支持快速切换

    // 应用信息缓存（PID -> (bundleID, icon, isHidden)）
    private var appInfoCache: [pid_t: (bundleIdentifier: String, icon: NSImage, isHidden: Bool)] = [:]
    private let appInfoCacheLock = NSLock()

    // 焦点窗口轮询定时器（用于监听同一应用内的窗口切换，如 Command+`）
    private var focusPollingTimer: Timer?
    private var lastFocusedWindowID: CGWindowID?

    private init() {}

    // 缓存的窗口列表
    var windows: [WindowModel] {
        getAllWindows()
    }

    deinit {
        stopFocusPolling()
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

        // 第一步：先通过 AXUIElement raise 窗口（在应用激活之前）
        // 这样可以确保窗口在应用内的层级最高
        if let win = axWindow(for: window) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        // 第二步：激活应用（将应用带到前台）
        let activateResult = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        if !activateResult {
            Logger.warning("NSRunningApplication.activate returned false for \(window.appName)")
        }

        // 第三步：再次确保窗口焦点（有时应用激活后会重置焦点）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, let win = self.axWindow(for: window) else { return }
            AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
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

        // 停止之前的轮询
        stopFocusPolling()

        // 监听应用激活事件，追踪外部窗口切换（窗口级别）
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }

            // 获取激活的应用
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            let pid = app.processIdentifier
            Logger.debug("==> External app activated: \(app.localizedName ?? "unknown"), PID: \(pid)")

            // 使用 AX API 获取当前焦点窗口（窗口级别追踪）
            let focusedWindowID = self.getFocusedWindowID(pid: pid)
            let now = Date()

            if let windowID = focusedWindowID, var model = self.windowCache[windowID] {
                // 只更新焦点窗口的 lastActiveTime
                model = WindowModel(
                    id: model.id,
                    appName: model.appName,
                    bundleIdentifier: model.bundleIdentifier,
                    windowTitle: model.windowTitle,
                    appIcon: model.appIcon,
                    frame: model.frame,
                    isMinimized: model.isMinimized,
                    isHidden: model.isHidden,
                    isOnScreen: model.isOnScreen,
                    lastActiveTime: now,
                    windowLayer: model.windowLayer,
                    ownerPID: model.ownerPID
                )
                self.windowCache[windowID] = model
                self.lastFocusedWindowID = windowID
                Logger.debug("==> Updated lastActiveTime for focused window: \(model.windowTitle)")
            } else {
                // 如果无法获取焦点窗口，更新该应用最新的窗口（降级方案）
                let appWindows = self.windowCache.filter { $0.value.ownerPID == pid }
                    .sorted { $0.value.lastActiveTime > $1.value.lastActiveTime }
                if let first = appWindows.first {
                    var model = first.value
                    model = WindowModel(
                        id: model.id,
                        appName: model.appName,
                        bundleIdentifier: model.bundleIdentifier,
                        windowTitle: model.windowTitle,
                        appIcon: model.appIcon,
                        frame: model.frame,
                        isMinimized: model.isMinimized,
                        isHidden: model.isHidden,
                        isOnScreen: model.isOnScreen,
                        lastActiveTime: now,
                        windowLayer: model.windowLayer,
                        ownerPID: model.ownerPID
                    )
                    self.windowCache[model.id] = model
                    Logger.debug("==> Fallback: Updated lastActiveTime for newest window: \(model.windowTitle)")
                }
            }

            // 清除缓存以便重新排序
            self.cacheTimestamp = nil
        }
        observers.append(token)

        // 启动焦点窗口轮询，监听同一应用内的窗口切换（如 Command+`）
        startFocusPolling()
    }

    // MARK: - 焦点窗口轮询

    /// 启动焦点窗口轮询定时器
    private func startFocusPolling() {
        focusPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollFocusedWindow()
        }
    }

    /// 停止焦点窗口轮询
    private func stopFocusPolling() {
        focusPollingTimer?.invalidate()
        focusPollingTimer = nil
    }

    /// 轮询检查焦点窗口变化
    private func pollFocusedWindow() {
        // 获取当前前台应用的焦点窗口
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontmostApp.processIdentifier

        guard let focusedWindowID = getFocusedWindowID(pid: pid) else { return }

        // 如果焦点窗口发生变化（同一应用内切换窗口）
        if focusedWindowID != lastFocusedWindowID {
            lastFocusedWindowID = focusedWindowID
            let now = Date()

            if var model = windowCache[focusedWindowID] {
                model = WindowModel(
                    id: model.id,
                    appName: model.appName,
                    bundleIdentifier: model.bundleIdentifier,
                    windowTitle: model.windowTitle,
                    appIcon: model.appIcon,
                    frame: model.frame,
                    isMinimized: model.isMinimized,
                    isHidden: model.isHidden,
                    isOnScreen: model.isOnScreen,
                    lastActiveTime: now,
                    windowLayer: model.windowLayer,
                    ownerPID: model.ownerPID
                )
                windowCache[focusedWindowID] = model
                Logger.debug("==> Focus window changed (same app): \(model.windowTitle)")

                // 清除缓存以便重新排序
                cacheTimestamp = nil

                // 通知事件处理器
                eventHandler?(.windowStateChanged(model))
            }
        }
    }

    /// 获取指定应用的焦点窗口 ID
    private func getFocusedWindowID(pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)

        // 获取焦点窗口
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let window = focusedWindow else {
            Logger.debug("==> Failed to get focused window for PID \(pid): \(result.rawValue)")
            return nil
        }

        // 通过私有 API 获取 CGWindowID
        var windowID: CGWindowID = 0
        let windowResult = _AXUIElementGetWindow(window as! AXUIElement, &windowID)

        guard windowResult == .success else {
            Logger.debug("==> Failed to get CGWindowID: \(windowResult.rawValue)")
            return nil
        }

        return windowID
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

        // 使用应用信息缓存，避免重复调用 NSRunningApplication
        let appInfo: (bundleIdentifier: String, icon: NSImage, isHidden: Bool)
        if let cached = appInfoCache[ownerPID] {
            appInfo = cached
        } else {
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let bundleID = app?.bundleIdentifier ?? ""
            let icon = app?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            let isHidden = app?.isHidden ?? false
            appInfo = (bundleID, icon, isHidden)
            appInfoCacheLock.lock()
            appInfoCache[ownerPID] = appInfo
            appInfoCacheLock.unlock()
        }

        // BUG-001: 通过 AX API 读取最小化状态，降级方案：isOnScreen=false && layer==0
        // 禁用 AX API 调用以提升性能，使用降级方案
        let isMinimized = !isOnScreen && layer == 0

        // BUG-011: lastActiveTime 始终为 Date()，无法反映真实 LRU 顺序
        // 改用 windowCache 中已有的时间戳，首次出现时才用 Date()
        let lastActive = windowCache[windowID]?.lastActiveTime ?? Date()

        return WindowModel(
            id: windowID,
            appName: appName,
            bundleIdentifier: appInfo.bundleIdentifier,
            windowTitle: windowTitle,
            appIcon: appInfo.icon,
            frame: frame,
            isMinimized: isMinimized,
            isHidden: appInfo.isHidden,
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
