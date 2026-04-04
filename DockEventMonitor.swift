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
            Logger.info("DockEventMonitor started")
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

        // 检查鼠标是否在 Dock 区域
        let isInDockArea = dockFrame.insetBy(dx: -20, dy: -20).contains(location)

        if isInDockArea {
            // 获取鼠标下的应用
            if let appBundleID = getAppBundleIDAtLocation(location) {
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
        // 方案 1: 使用专门的 Dock 图标检测（推荐）
        if let bundleID = getDockIconBundleIDAtLocation(location) {
            return bundleID
        }
        
        // 方案 2: 备用 - 使用 AXUIElement 获取鼠标位置的应用
        return getAppFromAXElement(at: location)
    }
    
    // MARK: - Dock 图标检测（通过 Accessibility API 直接查询 Dock）
    
    /// 通过 Accessibility API 直接获取 Dock 图标的 Bundle ID
    private func getDockIconBundleIDAtLocation(_ location: CGPoint) -> String? {
        // 1. 获取 Dock 进程的 AXUIElement
        guard let dockElement = findDockElement() else {
            Logger.debug("无法找到 Dock 元素")
            return nil
        }
        
        // 2. 将鼠标位置转换为 AX 坐标系（原点左上角，Y 向下）
        guard let screenHeight = NSScreen.main?.frame.height else { return nil }
        let axLocation = CGPoint(x: location.x, y: screenHeight - location.y)
        
        // 3. 遍历 Dock 子元素寻找匹配的图标
        return findDockIconAtPosition(dockElement, point: axLocation)
    }
    
    /// 查找 Dock 进程的 AXUIElement
    private func findDockElement() -> AXUIElement? {
        // 通过窗口列表查找 Dock
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            Logger.debug("[Dock] 无法获取窗口列表")
            return nil
        }
        
        Logger.debug("[Dock] 窗口数量: \(windowList.count)")
        
        for window in windowList {
            if let ownerName = window[kCGWindowOwnerName as String] as? String,
               ownerName == "Dock" {
                if let ownerPID = window[kCGWindowOwnerPID as String] as? Int32 {
                    Logger.debug("[Dock] 找到 Dock, PID: \(ownerPID)")
                    return AXUIElementCreateApplication(ownerPID)
                }
            }
        }
        
        Logger.debug("[Dock] 未找到 Dock 窗口")
        return nil
    }
    
    /// 在 Dock 元素中查找指定位置的图标
    private func findDockIconAtPosition(_ dockElement: AXUIElement, point: CGPoint) -> String? {
        var childrenRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef)
        
        guard result == .success, let children = childrenRef as? [AXUIElement] else {
            Logger.debug("无法获取 Dock 子元素: \(result.rawValue)")
            return nil
        }
        
        Logger.debug("Dock 子元素数量: \(children.count)")
        
        for (index, child) in children.enumerated() {
            // 获取图标的角色
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? "unknown"
            
            // 获取图标的位置和大小
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &positionRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                continue
            }
            
            var position = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            
            let iconRect = CGRect(origin: position, size: size)
            
            Logger.debug("图标 \(index): role=\(role), frame=\(iconRect)")
            
            // 检查鼠标是否在此图标范围内
            if iconRect.contains(point) {
                Logger.debug("✅ 匹配到图标 \(index), role=\(role)")
                
                // 尝试从图标获取应用信息
                if let bundleID = getBundleIDFromDockIcon(child) {
                    Logger.debug("✅ 获取到 Bundle ID: \(bundleID)")
                    return bundleID
                }
                
                // 如果无法获取 Bundle ID，尝试获取标题作为备用
                if let title = getIconTitle(child) {
                    Logger.debug("✅ 获取到标题: \(title)")
                    return bundleIDFromAppName(title)
                }
                
                // 尝试递归获取子元素
                if let bundleID = getBundleIDFromChildElements(child) {
                    Logger.debug("✅ 从子元素获取到 Bundle ID: \(bundleID)")
                    return bundleID
                }
                
                return nil
            }
        }
        
        return nil
    }
    
    /// 递归获取子元素中的 Bundle ID
    private func getBundleIDFromChildElements(_ element: AXUIElement) -> String? {
        var childrenRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        
        guard result == .success, let children = childrenRef as? [AXUIElement], !children.isEmpty else {
            return nil
        }
        
        for child in children {
            if let bundleID = getBundleIDFromDockIcon(child) {
                return bundleID
            }
            
            // 继续递归
            if let bundleID = getBundleIDFromChildElements(child) {
                return bundleID
            }
        }
        
        return nil
    }
    
    /// 从 Dock 图标元素获取 Bundle ID
    private func getBundleIDFromDockIcon(_ icon: AXUIElement) -> String? {
        // 方法 1: 尝试通过 description 获取（通常包含应用信息）
        var descRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(icon, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let description = descRef as? String, !description.isEmpty {
            // 尝试从描述中提取 Bundle ID 或应用名
            if let bundleID = bundleIDFromAppName(description) {
                return bundleID
            }
        }
        
        // 方法 2: 尝试通过 value 获取
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(icon, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String, !value.isEmpty {
            if let bundleID = bundleIDFromAppName(value) {
                return bundleID
            }
        }
        
        // 方法 3: 尝试通过 title 获取
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(icon, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, !title.isEmpty {
            if let bundleID = bundleIDFromAppName(title) {
                return bundleID
            }
        }
        
        return nil
    }
    
    /// 获取图标标题
    private func getIconTitle(_ element: AXUIElement) -> String? {
        let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        
        for attr in attributes {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &valueRef) == .success,
               let value = valueRef as? String, !value.isEmpty {
                return value
            }
        }
        
        return nil
    }
    
    /// 根据应用名称查找 Bundle ID
    private func bundleIDFromAppName(_ name: String) -> String? {
        // 查找运行中的应用
        let runningApps = NSWorkspace.shared.runningApplications
        
        // 精确匹配
        if let app = runningApps.first(where: { $0.localizedName == name }) {
            return app.bundleIdentifier
        }
        
        // 包含匹配（不区分大小写）
        if let app = runningApps.first(where: {
            $0.localizedName?.lowercased().contains(name.lowercased()) ?? false ||
            $0.bundleIdentifier?.lowercased().contains(name.lowercased()) ?? false
        }) {
            return app.bundleIdentifier
        }
        
        return nil
    }
    
    /// 备用方案：使用 AXUIElementCopyElementAtPosition（原有方法）
    private func getAppFromAXElement(at location: CGPoint) -> String? {
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

