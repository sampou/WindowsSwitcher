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
    func getAllWindows(forceRefresh: Bool) -> [WindowModel]
    func getWindows(for appName: String) -> [WindowModel]
    func activateWindow(_ window: WindowModel)
    func closeWindow(_ window: WindowModel)
    func minimizeWindow(_ window: WindowModel)
    func hideWindow(_ window: WindowModel)
    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void)
    func refreshCache()
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
    private let cacheTTL: TimeInterval = 0.1 // 100ms 缓存，支持快速切换

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

    func getAllWindows(forceRefresh: Bool = false) -> [WindowModel] {
        // 强制刷新时清除缓存时间戳
        if forceRefresh {
            cacheTimestamp = nil
        }

        // 使用缓存，避免频繁调用
        let now = Date()
        if !forceRefresh,
           let timestamp = cacheTimestamp,
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
        // 操作日志：开始激活窗口
        Logger.operation("窗口激活开始", detail: "\(window.appName) - \(window.windowTitle) (ID: \(window.id), PID: \(window.ownerPID))")

        // 获取应用实例
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
            Logger.warning("Failed to get NSRunningApplication for PID: \(window.ownerPID), trying bundleID")

            // 降级：尝试通过 bundleIdentifier 查找应用
            let bundleID = window.bundleIdentifier
            if let appByBundle = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                let result = appByBundle.activate(options: [.activateIgnoringOtherApps])
                Logger.operation("窗口激活", detail: "通过 bundleID 激活", result: result ? "成功" : "失败")
            }
            return
        }

        // 持久化保存窗口活动时间（异步执行，不阻塞激活）
        DispatchQueue.global(qos: .utility).async {
            WindowActivityStore.shared.saveLastActiveTime(
                bundleIdentifier: window.bundleIdentifier,
                windowTitle: window.windowTitle,
                time: Date()
            )
        }

        // 检查目标应用是否已经是前台应用
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier

        if isFrontmost {
            // 同一应用内切换窗口：直接聚焦目标窗口
            Logger.operation("应用内切换", detail: "\(window.appName) - \(window.windowTitle)", result: "直接聚焦")
            focusWindowQuick(window)
        } else {
            // 不同应用间切换：先激活应用，再聚焦窗口
            Logger.operation("跨应用切换", detail: "激活 \(window.appName) - \(window.windowTitle)", result: "激活应用")
            let _ = app.activate(options: [.activateIgnoringOtherApps])
            // 跨应用切换需要短暂延迟再聚焦，等待应用激活完成
            // 某些重型应用（如 Navicat）激活较慢，立即调用 AX API 会超时或匹配失败
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusWindowQuick(window)
            }
        }

        Logger.operation("窗口激活完成", detail: "\(window.appName) - \(window.windowTitle)")
    }

    /// 快速聚焦窗口（简化版，减少 AX 调用）
    private func focusWindowQuick(_ window: WindowModel) {
        guard let win = axWindow(for: window) else { return }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    /// 聚焦指定窗口
    private func focusWindow(_ window: WindowModel, retryCount: Int) {
        guard let win = axWindow(for: window) else {
            Logger.warning("Cannot find AXUIElement for window: \(window.windowTitle)")

            // 重试（减少延迟）
            if retryCount < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.focusWindow(window, retryCount: retryCount + 1)
                }
            }
            return
        }

        // 先 raise 窗口，再设置焦点
        let raiseResult = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        Logger.operation("AX 操作", detail: "raise=\(raiseResult.rawValue), focus=\(focusResult.rawValue)",
                         result: raiseResult == .success && focusResult == .success ? "成功" : "部分失败")

        if focusResult != .success || raiseResult != .success {
            // 再尝试一次（减少延迟）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self = self, let win = self.axWindow(for: window) else { return }
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
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

            // 如果焦点轮询被暂停，跳过处理
            if self.focusPollingPaused { return }

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
                    ownerPID: model.ownerPID,
                    isStandardWindow: model.isStandardWindow
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
                        ownerPID: model.ownerPID,
                        isStandardWindow: model.isStandardWindow
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

    // MARK: - 焦点轮询暂停（切换面板打开时暂停，避免窗口列表变化）

    private var focusPollingPaused = false

    /// 暂停焦点轮询（切换面板打开时调用）
    func pauseFocusPolling() {
        focusPollingPaused = true
    }

    /// 恢复焦点轮询（切换面板关闭时调用）
    func resumeFocusPolling() {
        focusPollingPaused = false
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
        // 如果焦点轮询被暂停，跳过处理
        guard !focusPollingPaused else { return }

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
                    ownerPID: model.ownerPID,
                    isStandardWindow: model.isStandardWindow
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
        // 优先级：内存缓存 > 持久化存储 > 当前时间
        // 新窗口（不在缓存中）且在屏幕上：直接用 Date()，避免 WindowActivityStore
        // 返回旧时间戳导致新窗口排序靠后（如同名浏览器标签）
        let lastActive: Date
        if let cached = windowCache[windowID]?.lastActiveTime {
            lastActive = cached
        } else if isOnScreen {
            lastActive = Date()
        } else {
            lastActive = WindowActivityStore.shared.getLastActiveTime(
                bundleIdentifier: appInfo.bundleIdentifier,
                windowTitle: windowTitle
            ) ?? Date()
        }

        Logger.debug("Window \(appName) - \(windowTitle): lastActiveTime = \(lastActive)")

        // 判断是否为标准窗口
        let isStandardWindow = !NonStandardWindowRules.isNonStandardWindow(
            bundleIdentifier: appInfo.bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            frame: frame,
            windowLayer: layer
        )

        // 如果不是标准窗口，直接返回 nil（不包含在窗口列表中）
        guard isStandardWindow else {
            Logger.debug("Skipping non-standard window: \(appName) - \(windowTitle) [\(frame.width)x\(frame.height)]")
            return nil
        }

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
            ownerPID: ownerPID,
            isStandardWindow: isStandardWindow
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

    /// 用 CGWindowID 匹配 AXUIElement，比标题匹配更可靠
    /// 如果精确匹配失败，返回 nil 而不是降级到第一个窗口（避免切换到错误窗口）
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

        // 优先：通过 CGWindowID 精确匹配
        for win in wins {
            var cgWinID: CGWindowID = 0
            if _AXUIElementGetWindow(win, &cgWinID) == .success, cgWinID == model.id {
                Logger.debug("Matched window by CGWindowID: \(cgWinID)")
                return win
            }
        }

        // 次选：通过窗口标题精确匹配
        for win in wins {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title == model.windowTitle {
                Logger.debug("Matched window by title: \(title)")
                return win
            }
        }

        // 第三选择：通过窗口位置匹配（如果窗口标题不唯一）
        for win in wins {
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?

            AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &positionRef)
            AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)

            if let positionValue = positionRef, let sizeValue = sizeRef {
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

                // 检查位置和大小是否匹配
                if abs(position.x - model.frame.origin.x) < 5 &&
                   abs(position.y - model.frame.origin.y) < 5 &&
                   abs(size.width - model.frame.width) < 5 &&
                   abs(size.height - model.frame.height) < 5 {
                    Logger.debug("Matched window by position/size: \(position), \(size)")
                    return win
                }
            }
        }

        // 如果所有精确匹配都失败，打印警告并返回 nil（不再降级到第一个窗口）
        Logger.warning("No matching window found for: \(model.windowTitle), available windows: \(wins.count)")
        return nil
    }
}
