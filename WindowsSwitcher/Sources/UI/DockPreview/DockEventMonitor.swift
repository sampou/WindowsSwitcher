import Foundation
import AppKit
import ApplicationServices
import Combine

// MARK: - DockIconInfo
/// Dock 图标信息结构体
struct DockIconInfo {
    let bundleID: String
    let frame: CGRect  // 图标在屏幕上的位置（macOS 坐标系）
    let center: CGPoint  // 图标中心点
}

// MARK: - DockEventMonitor
/// 程序坞图标事件监听器
class DockEventMonitor: ObservableObject {
    @Published var hoveredAppBundleID: String?
    @Published var isDockVisible: Bool = true
    @Published var dockPosition: DockPosition = .bottom
    @Published var hoveredIconInfo: DockIconInfo?
    @Published var isMouseInPreviewWindow: Bool = false  // 鼠标是否在预览窗口内
    @Published var mouseLocation: CGPoint = .zero  // 当前鼠标位置

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hoverTimer: Timer?
    private var hideTimer: Timer?  // 延迟隐藏计时器

    // MARK: - 缓存
    private var dockAppsListCache: [(String, String)]?
    private var dockAppsListCacheTime: Date?
    private let cacheExpiryInterval: TimeInterval = 2.0  // 缓存 2 秒过期（更及时更新）

    // 运行中应用的快速查找字典（名称 -> bundleID）
    private var runningAppsLookup: [String: String] = [:]
    private var runningAppsLookupTime: Date?

    // 追踪之前是否在 Dock 区域
    private var wasInDockArea: Bool = false

    /// 悬停延迟
    private var hoverDelay: TimeInterval {
        ConfigManager.shared.config.dockPreview.hoverDelay
    }

    /// 隐藏延迟
    private var hideDelay: TimeInterval {
        ConfigManager.shared.config.dockPreview.hideDelay
    }

    init() {
        setupDockMonitoring()
        checkAccessibilityPermission()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    func startMonitoring() {
        guard globalMouseMonitor == nil else { return }

        // 使用 NSEvent 全局监听鼠标移动
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseMoved(event)
        }

        // 本地监听器（用于应用内）
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseMoved(event)
            return event
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        mouseLocation = location

        let dockFrame = getDockFrame()
        let expandedDockFrame = dockFrame.insetBy(dx: -30, dy: -30)
        let isInDockArea = expandedDockFrame.contains(location)

        // 检测进入/离开 Dock 区域状态变化
        if isInDockArea && !wasInDockArea {
            // 刚进入 Dock 区域，预先构建缓存
            _ = getDockAppOrderWithBundleID()
            _ = getRunningAppsLookup()
            Logger.debug("[Dock] 进入 Dock 区域，缓存已构建")
        } else if !isInDockArea && wasInDockArea {
            // 刚离开 Dock 区域，清除缓存
            invalidateCaches()
            Logger.debug("[Dock] 离开 Dock 区域，缓存已清除")
        }
        wasInDockArea = isInDockArea

        // 检查是否在 Dock 区域或预览窗口内
        if isInDockArea {
            // 在 Dock 区域，尝试检测具体应用图标
            if let iconInfo = getDockIconInfoAtLocation(location) {
                // 成功检测到图标，启动悬停计时器
                startHoverTimer(for: iconInfo)
            } else {
                // 未检测到图标（可能在 Dock 的空白区域），清除状态
                cancelHoverTimer()
                startHideTimer()
            }
            // 取消隐藏计时器
            hideTimer?.invalidate()
            hideTimer = nil
        } else if isMouseInPreviewWindow {
            // 在预览窗口内，保持显示
            hoverTimer?.invalidate()
            hideTimer?.invalidate()
            hideTimer = nil
        } else {
            // 既不在 Dock 也不在预览窗口，启动隐藏计时器
            cancelHoverTimer()
            startHideTimer()
        }
    }

    /// 检查鼠标是否在预览窗口区域内
    func checkMouseInPreviewWindow(previewFrame: CGRect) {
        let isInPreview = previewFrame.contains(mouseLocation)
        isMouseInPreviewWindow = isInPreview

        if isInPreview {
            // 鼠标进入预览窗口，取消隐藏计时器
            hideTimer?.invalidate()
            hideTimer = nil
        } else {
            // 鼠标离开预览窗口，检查是否也在 Dock 区域
            let dockFrame = getDockFrame()
            let isInDockArea = dockFrame.insetBy(dx: -30, dy: -30).contains(mouseLocation)

            if !isInDockArea {
                // 也不在 Dock 区域，启动隐藏计时器
                startHideTimer()
            }
        }
    }

    func startHideTimer() {
        guard hideTimer == nil else { return }

        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hoveredAppBundleID = nil
                self?.hoveredIconInfo = nil
                self?.isMouseInPreviewWindow = false
                // 隐藏时清除缓存，确保下次获取最新数据
                self?.invalidateCaches()
            }
        }
    }

    /// 重置所有状态（在预览窗口被点击后调用）
    func resetState() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        isMouseInPreviewWindow = false
        // 重置所有悬停状态
        hoveredAppBundleID = nil
        hoveredIconInfo = nil
        // 清除缓存，确保下次获取最新数据
        invalidateCaches()
    }

    /// 清除所有缓存
    private func invalidateCaches() {
        dockAppsListCache = nil
        dockAppsListCacheTime = nil
        runningAppsLookup = [:]
        runningAppsLookupTime = nil
    }

    // 获取 Dock 图标信息（包含精确位置）
    func getDockIconInfoAtLocation(_ location: CGPoint) -> DockIconInfo? {
        guard let screenHeight = NSScreen.main?.frame.height else { return nil }

        // 转换到 AX 坐标系
        let axLocation = CGPoint(x: location.x, y: screenHeight - location.y)

        // 找到 Dock 进程
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return nil
        }

        let dockPID = dockApp.processIdentifier
        let dockElement = AXUIElementCreateApplication(dockPID)

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            if role == "AXList" || role == "AXScrollArea" || role == "AXGroup" {
                var listChildrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenRef) == .success,
                   let listChildren = listChildrenRef as? [AXUIElement] {

                    Logger.debug("[Dock AX] AX 图标元素总数: \(listChildren.count)")

                    for (childIdx, listChild) in listChildren.enumerated() {
                        var positionRef: CFTypeRef?
                        var sizeRef: CFTypeRef?

                        guard AXUIElementCopyAttributeValue(listChild, kAXPositionAttribute as CFString, &positionRef) == .success,
                              AXUIElementCopyAttributeValue(listChild, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                            continue
                        }

                        var position = CGPoint.zero
                        var size = CGSize.zero
                        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

                        let iconRect = CGRect(origin: position, size: size)

                        if iconRect.contains(axLocation) {
                            // 尝试多种方式获取 bundleID
                            var bundleID: String?

                            // 方法1: 从图标元素获取
                            bundleID = getBundleIDFromDockIcon(listChild)

                            // 方法2: 通过索引获取（后备方案）
                            if bundleID == nil {
                                bundleID = getBundleIDByDockIndex(childIdx)
                            }

                            // 方法3: 通过图标描述匹配运行中的应用（适用于未保留在程序坞的应用）
                            if bundleID == nil {
                                bundleID = getBundleIDFromRunningApps(listChild)
                            }

                            if let bundleID = bundleID {
                                // 转换回 macOS 屏幕坐标系
                                let macFrame = CGRect(
                                    x: iconRect.origin.x,
                                    y: screenHeight - iconRect.origin.y - iconRect.size.height,
                                    width: iconRect.size.width,
                                    height: iconRect.size.height
                                )
                                let center = CGPoint(x: macFrame.midX, y: macFrame.midY)

                                Logger.debug("[Dock AX] getDockIconInfoAtLocation 成功: \(bundleID), center=\(center)")
                                return DockIconInfo(bundleID: bundleID, frame: macFrame, center: center)
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    // 转换屏幕坐标
    private func getAppBundleIDAtScreenLocation(_ location: CGPoint) -> String? {
        // 先尝试 Accessibility API
        if let bundleID = getAppBundleIDViaAccessibility(location) {
            if bundleID != "com.apple.dock" {
                return bundleID
            }
        }

        // Accessibility 返回 Dock，优先使用位置估算
        if let bundleID = getAppBundleIDViaDockPosition(location) {
            return bundleID
        }

        // 最后才使用前台应用作为后备（仅当位置估算失败时）
        if let bundleID = getForegroundAppBundleID() {
            Logger.info("  [检测] 前台应用(后备): \(bundleID)")
            return bundleID
        }

        return nil
    }

    // 获取当前前台应用的 Bundle ID
    private func getForegroundAppBundleID() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return frontApp.bundleIdentifier
    }

    // 使用 Accessibility API 获取应用
    private func getAppBundleIDViaAccessibility(_ location: CGPoint) -> String? {
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

    // 使用 Accessibility API 遍历 Dock 进程获取图标位置
    private func getAppBundleIDViaDockPosition(_ location: CGPoint) -> String? {
        let dockFrame = getDockFrame()
        Logger.info("  [计算] dockFrame: \(dockFrame), dockPosition: \(dockPosition)")

        // 检查鼠标是否在 Dock 区域
        let insetFrame = dockFrame.insetBy(dx: -30, dy: -30)

        guard insetFrame.contains(location) else {
            return nil
        }

        // 方法1: 尝试使用 Accessibility API 遍历 Dock 获取图标位置
        let (axBundleID, axIconIndex) = getDockIconBundleIDViaAccessibility(location)
        if let bid = axBundleID, bid != "com.apple.dock" {
            Logger.info("  [计算] AX方法找到: \(bid), 索引: \(axIconIndex ?? -1)")
            return bid
        }

        // 方法2: 尝试使用 CGWindowListCopyWindowInfo 获取窗口信息
        if let windowBundleID = getBundleIDViaWindowList(at: location) {
            Logger.info("  [计算] 窗口列表方法找到: \(windowBundleID)")
            return windowBundleID
        }

        // 方法3: 使用 Dock 应用列表和精确位置计算（最后的备用方案）
        let dockAppsList = getDockAppOrderWithBundleID()

        guard dockAppsList.count > 0 else {
            return nil
        }

        // 获取 dock 配置参数
        let dockConfig = getDockConfig()
        let iconSize = dockConfig.iconSize
        let spacing = dockConfig.spacing

        // 计算每个图标的实际位置和区域
        let dockAppsCount = dockAppsList.count

        // 计算 dock 图标区域的总宽度（仅计算应用图标，不含分隔符等）
        let totalWidth = dockFrame.width
        let iconRegionWidth = CGFloat(dockAppsCount) * iconSize + CGFloat(dockAppsCount - 1) * spacing

        // 图标区域起始位置（居中）
        let startX = (totalWidth - iconRegionWidth) / 2

        // 根据鼠标 x 位置计算在第几个图标
        let relativeX = location.x - startX
        let index: Int
        if relativeX < 0 {
            index = 0
        } else {
            let adjustedX = relativeX / (iconSize + spacing)
            index = Int(adjustedX)
        }

        let safeIndex = max(0, min(index, dockAppsCount - 1))

        Logger.info("  [计算] iconSize: \(iconSize), spacing: \(spacing), startX: \(startX), index: \(index), safeIndex: \(safeIndex)")

        let (_, bundleID) = dockAppsList[safeIndex]
        Logger.info("  [计算] 位置估算: \(bundleID)")
        return bundleID
    }

    // 获取 Dock 配置参数
    private func getDockConfig() -> (iconSize: CGFloat, spacing: CGFloat) {
        let defaults = UserDefaults(suiteName: "com.apple.dock")!

        // 图标大小
        let iconSize = CGFloat(defaults.double(forKey: "size"))

        // 图标间距
        let spacing = CGFloat(defaults.double(forKey: "spacing"))

        // 如果获取不到，使用默认值
        let finalIconSize = iconSize > 0 ? iconSize : 48
        let finalSpacing = spacing > 0 ? spacing : 8

        return (finalIconSize, finalSpacing)
    }

    // 使用 Accessibility API 遍历 Dock 进程的图标元素
    // 返回值改为 (bundleID, iconIndex) 元组，这样可以使用索引来查找
    private func getDockIconBundleIDViaAccessibility(_ location: CGPoint) -> (String?, Int?) {
        Logger.debug("[Dock AX] 开始查找 Dock 图标, 鼠标位置: \(location)")

        // 找到 Dock 进程
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            Logger.debug("[Dock AX] 未找到 Dock 进程")
            return (nil, nil)
        }

        let dockPID = dockApp.processIdentifier
        let dockElement = AXUIElementCreateApplication(dockPID)

        Logger.debug("[Dock AX] Dock PID: \(dockPID)")

        // 获取 Dock 的所有子元素
        var childrenRef: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef)

        guard childrenResult == .success, let children = childrenRef as? [AXUIElement] else {
            Logger.debug("[Dock AX] 无法获取 Dock 子元素: \(childrenResult.rawValue)")
            return (nil, nil)
        }

        Logger.debug("[Dock AX] Dock 子元素数量: \(children.count)")

        // 获取屏幕高度用于坐标转换
        guard let screenHeight = NSScreen.main?.frame.height else {
            return (nil, nil)
        }

        // 转换鼠标位置到 AX 坐标系（原点左上角）
        let axLocation = CGPoint(x: location.x, y: screenHeight - location.y)

        // 遍历 Dock 的所有子元素
        for (index, child) in children.enumerated() {
            // 获取元素角色
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? "unknown"

            // 获取元素描述
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descRef)
            let description = descRef as? String

            // 获取位置和大小
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

            Logger.debug("[Dock AX] 元素 \(index): role=\(role), desc=\(description ?? "nil"), frame=\(iconRect)")

            // 检查鼠标是否在此元素范围内
            if iconRect.contains(axLocation) {
                Logger.debug("[Dock AX] ✅ 匹配到元素 \(index), role=\(role)")

                // 如果是容器类型（AXList/AXScrollArea/AXGroup），遍历子元素找图标
                if role == "AXList" || role == "AXScrollArea" || role == "AXGroup" {
                    Logger.debug("[Dock AX] 容器类型，遍历子元素查找图标")

                    var listChildrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenRef) == .success,
                       let listChildren = listChildrenRef as? [AXUIElement] {

                        Logger.debug("[Dock AX] 子元素数量: \(listChildren.count)")

                        for (childIdx, listChild) in listChildren.enumerated() {
                            // 获取子元素的位置
                            var childPosRef: CFTypeRef?
                            var childSizeRef: CFTypeRef?

                            guard AXUIElementCopyAttributeValue(listChild, kAXPositionAttribute as CFString, &childPosRef) == .success,
                                  AXUIElementCopyAttributeValue(listChild, kAXSizeAttribute as CFString, &childSizeRef) == .success else {
                                continue
                            }

                            var childPos = CGPoint.zero
                            var childSize = CGSize.zero
                            AXValueGetValue(childPosRef as! AXValue, .cgPoint, &childPos)
                            AXValueGetValue(childSizeRef as! AXValue, .cgSize, &childSize)

                            let childRect = CGRect(origin: childPos, size: childSize)

                            // 获取子元素角色
                            var childRoleRef: CFTypeRef?
                            AXUIElementCopyAttributeValue(listChild, kAXRoleAttribute as CFString, &childRoleRef)
                            let childRole = childRoleRef as? String ?? "unknown"

                            Logger.debug("[Dock AX]   子元素 \(childIdx): role=\(childRole), frame=\(childRect)")

                            // 检查鼠标是否在这个子元素内
                            if childRect.contains(axLocation) {
                                Logger.debug("[Dock AX]   ✅ 匹配到子元素 \(childIdx)")

                                // 尝试从子元素获取 Bundle ID
                                if let bundleID = getBundleIDFromDockIcon(listChild) {
                                    Logger.debug("[Dock AX]   ✅ 从子元素获取到: \(bundleID)")
                                    return (bundleID, childIdx)
                                }

                                // 如果无法获取 bundle ID，尝试通过索引查找
                                if let bundleID = getBundleIDByDockIndex(childIdx) {
                                    Logger.debug("[Dock AX]   ✅ 通过索引获取到: \(bundleID)")
                                    return (bundleID, childIdx)
                                }
                            }
                        }
                    }
                } else {
                    // 非容器类型，直接尝试获取应用信息
                    if let bundleID = getBundleIDFromDockIcon(child) {
                        Logger.debug("[Dock AX] ✅ 获取到 Bundle ID: \(bundleID)")
                        return (bundleID, index)
                    }

                    // 如果无法获取 bundle ID，尝试通过索引查找
                    if let bundleID = getBundleIDByDockIndex(index) {
                        Logger.debug("[Dock AX] ✅ 通过索引获取到: \(bundleID)")
                        return (bundleID, index)
                    }
                }
            }
        }

        Logger.debug("[Dock AX] 未找到匹配的图标")
        return (nil, nil)
    }

    // 新增: 通过 Dock 索引获取 bundle ID
    private func getBundleIDByDockIndex(_ index: Int) -> String? {
        let dockAppsList = getDockAppOrderWithBundleID()

        Logger.debug("[Dock AX] 索引映射: 请求索引=\(index), 列表总数=\(dockAppsList.count)")

        guard index >= 0 && index < dockAppsList.count else {
            Logger.warning("[Dock AX] 索引越界: index=\(index), count=\(dockAppsList.count)")
            return nil
        }

        let (appName, bundleID) = dockAppsList[index]
        Logger.debug("[Dock AX] 通过索引 \(index) 获取到: \(appName) -> \(bundleID)")
        return bundleID
    }

    // 通过 AX 图标元素匹配运行中的应用（适用于未保留在程序坞的应用）
    private func getBundleIDFromRunningApps(_ iconElement: AXUIElement) -> String? {
        // 获取图标的 title 或 description
        var titleRef: CFTypeRef?
        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(iconElement, kAXTitleAttribute as CFString, &titleRef)
        AXUIElementCopyAttributeValue(iconElement, kAXDescriptionAttribute as CFString, &descRef)

        let title = titleRef as? String
        let description = descRef as? String
        let iconName = title ?? description ?? ""

        guard !iconName.isEmpty else {
            return nil
        }

        // 使用缓存的快速查找字典
        let lookup = getRunningAppsLookup()

        // 精确匹配（不区分大小写）
        let lowercasedName = iconName.lowercased()
        if let bundleID = lookup[lowercasedName] {
            return bundleID
        }

        // 部分匹配（遍历查找字典）
        for (appName, bundleID) in lookup {
            if appName.contains(lowercasedName) || lowercasedName.contains(appName) {
                return bundleID
            }
        }

        Logger.debug("[Dock AX] 未匹配到运行中应用: \(iconName)")
        return nil
    }

    // 获取运行中应用的快速查找字典（带缓存）
    private func getRunningAppsLookup() -> [String: String] {
        // 检查缓存是否有效
        if let cacheTime = runningAppsLookupTime,
           Date().timeIntervalSince(cacheTime) < cacheExpiryInterval,
           !runningAppsLookup.isEmpty {
            return runningAppsLookup
        }

        // 重建查找字典
        var lookup: [String: String] = [:]
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            guard app.activationPolicy == .regular,
                  let name = app.localizedName,
                  let bundleID = app.bundleIdentifier else { continue }

            lookup[name.lowercased()] = bundleID
        }

        // 更新缓存
        runningAppsLookup = lookup
        runningAppsLookupTime = Date()

        Logger.debug("[Dock] 运行中应用查找字典已更新, 数量: \(lookup.count)")
        return lookup
    }

    // 检查图标元素是否匹配
    private func checkIconElement(_ element: AXUIElement, at point: CGPoint) -> String? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        
        let iconRect = CGRect(origin: position, size: size)
        
        if iconRect.contains(point) {
            // 获取角色和描述
            var roleRef: CFTypeRef?
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
            
            let role = roleRef as? String ?? "unknown"
            let desc = descRef as? String ?? "nil"
            
            Logger.debug("[Dock AX]   子元素匹配: role=\(role), desc=\(desc)")
            
            if let bundleID = getBundleIDFromDockIcon(element) {
                return bundleID
            }
        }
        
        return nil
    }
    
    // 递归获取子元素中的 Bundle ID
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

    // 获取 AX 元素的 frame
    private func getAXElementFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)

        guard posResult == .success, sizeResult == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        if let posValue = positionRef {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }
        if let sizeValue = sizeRef {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }

        // macOS 坐标转换
        if let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            position.y = screenHeight - position.y - size.height
        }

        return CGRect(origin: position, size: size)
    }

    // 从 Dock 图标元素获取 bundle ID
    private func getBundleIDFromDockIcon(_ iconElement: AXUIElement) -> String? {
        // 方法1: 尝试获取图标的 title 或 description
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(iconElement, kAXTitleAttribute as CFString, &titleRef)

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(iconElement, kAXDescriptionAttribute as CFString, &descRef)

        let title = titleRef as? String
        let description = descRef as? String

        // 方法2: 尝试通过 UI 元素获取应用信息
        // 有时图标有子元素包含应用信息
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(iconElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {

            for child in children {
                // 检查是否有链接到应用的元素
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXURLAttribute as CFString, &urlRef) == .success,
                   let url = urlRef as? URL,
                   let bundle = Bundle(url: url),
                   let bundleID = bundle.bundleIdentifier {
                    return bundleID
                }
            }
        }

        // 方法3: 尝试从 AXDockItem 获取 PID 属性（某些版本的 macOS 支持）
        if let bundleID = getBundleIDFromDockIconByPID(iconElement) {
            return bundleID
        }

        // 方法4: 尝试通过图标名称匹配 Dock 应用列表（改进版）
        if let bundleID = matchDockIconByName(title: title, description: description) {
            return bundleID
        }

        return nil
    }

    // 新增: 从 AXDockItem 尝试获取 PID，然后从 PID 获取 bundle ID
    private func getBundleIDFromDockIconByPID(_ iconElement: AXUIElement) -> String? {
        // 尝试获取 DockItem 的 PID 属性
        var pidRef: CFTypeRef?
        let pidResult = AXUIElementCopyAttributeValue(iconElement, "AXPid" as CFString, &pidRef)

        if pidResult == .success, let pidValue = pidRef {
            if let pid = pidValue as? pid_t,
               let app = NSRunningApplication(processIdentifier: pid),
               let bundleID = app.bundleIdentifier {
                Logger.debug("[Dock AX] 通过 PID 获取到 bundleID: \(bundleID)")
                return bundleID
            } else if let pidNumber = pidValue as? NSNumber {
                let pid = pidNumber.int32Value
                if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                   let bundleID = app.bundleIdentifier {
                    Logger.debug("[Dock AX] 通过 PID 获取到 bundleID: \(bundleID)")
                    return bundleID
                }
            }
        }

        // 尝试获取 AXDocument 属性（某些情况下包含应用路径）
        var docRef: CFTypeRef?
        let docResult = AXUIElementCopyAttributeValue(iconElement, kAXDocumentAttribute as CFString, &docRef)

        if docResult == .success, let docValue = docRef {
            if let url = docValue as? URL, let bundleID = Bundle(url: url)?.bundleIdentifier {
                Logger.debug("[Dock AX] 通过 Document 属性获取到 bundleID: \(bundleID)")
                return bundleID
            } else if let urlString = docValue as? String, let url = URL(string: urlString) {
                if let bundleID = Bundle(url: url)?.bundleIdentifier {
                    Logger.debug("[Dock AX] 通过 Document 属性获取到 bundleID: \(bundleID)")
                    return bundleID
                }
            }
        }

        return nil
    }

    // 新增: 改进的名称匹配方法
    private func matchDockIconByName(title: String?, description: String?) -> String? {
        let iconName = title ?? description ?? ""
        guard !iconName.isEmpty else { return nil }

        let dockAppsList = getDockAppOrderWithBundleID()

        // 首先尝试精确匹配（不区分大小写）
        for (appName, bundleID) in dockAppsList {
            if iconName.lowercased() == appName.lowercased() {
                return bundleID
            }
        }

        // 然后尝试部分匹配
        for (appName, bundleID) in dockAppsList {
            if iconName.lowercased().contains(appName.lowercased()) ||
               appName.lowercased().contains(iconName.lowercased()) {
                return bundleID
            }
        }

        // 尝试匹配本地化名称（中文名称匹配）
        // 例如 "访达" 匹配 "Finder", "微信" 匹配 "WeChat"
        let localizedMapping: [String: String] = [
            "访达": "Finder",
            "系统设置": "System Settings",
            "谷歌浏览器": "Google Chrome",
            "微软 Edge": "Microsoft Edge",
            "Chrome": "Google Chrome",
            "Edge": "Microsoft Edge",
            "QQ": "com.tencent.qq",
            "微信": "com.tencent.xinWeChat",
            "有道云笔记": "com.youdao.yunNote",
            "网易云音乐": "com.netease.cloudmusic",
            "记事本": "NotepadNext"
        ]

        for (localName, appNameOrBundleID) in localizedMapping {
            if iconName.contains(localName) {
                // 先尝试作为应用名称匹配
                for (appName, bundleID) in dockAppsList {
                    if appName.lowercased().contains(appNameOrBundleID.lowercased()) {
                        return bundleID
                    }
                }
                // 如果作为应用名称没找到，直接作为 bundle ID 匹配
                if let bundleID = dockAppsList.first(where: { $0.1 == appNameOrBundleID })?.1 {
                    return bundleID
                }
            }
        }

        return nil
    }

    // 新增: 使用 CGWindowListCopyWindowInfo 获取鼠标位置下的窗口对应的应用
    private func getBundleIDViaWindowList(at point: CGPoint) -> String? {
        // 获取屏幕高度用于坐标转换
        guard let screenHeight = NSScreen.main?.frame.height else {
            return nil
        }

        // 转换坐标: NSEvent 坐标 (y=0 在底部) -> CGWindow 坐标 (y=0 在顶部)
        let flippedY = screenHeight - point.y

        // 获取鼠标位置下的窗口
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            // 获取窗口 bounds
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }

            let windowX = boundsDict["X"] ?? 0
            let windowY = boundsDict["Y"] ?? 0
            let windowWidth = boundsDict["Width"] ?? 0
            let windowHeight = boundsDict["Height"] ?? 0

            // 检查鼠标是否在窗口内
            // 注意: CGWindow 的 y 坐标是从屏幕顶部计算的
            let windowTop = windowY
            let windowBottom = windowY + windowHeight

            // 鼠标 y 坐标需要翻转
            if point.x >= windowX && point.x <= windowX + windowWidth &&
               flippedY >= windowTop && flippedY <= windowBottom {

                // 获取窗口所有者（应用）
                if let app = NSRunningApplication(processIdentifier: ownerPID),
                   let bundleID = app.bundleIdentifier {
                    // 排除系统进程
                    if bundleID != "com.apple.dock" && bundleID != "com.apple.WindowManager" {
                        Logger.debug("[Dock AX] 通过窗口列表获取到 bundleID: \(bundleID)")
                        return bundleID
                    }
                }
            }
        }

        return nil
    }

    // 获取 Dock 的应用列表（有序数组：[(应用名, Bundle ID)]）
    private func getDockAppOrderWithBundleID() -> [(String, String)] {
        // 检查缓存是否有效
        if let cache = dockAppsListCache,
           let cacheTime = dockAppsListCacheTime,
           Date().timeIntervalSince(cacheTime) < cacheExpiryInterval {
            return cache
        }

        var dockAppsList: [(String, String)] = []

        // 先读取 persistent-apps（固定的应用）
        if let persistentApps = getAppsFromDockPlist(key: "persistent-apps") {
            dockAppsList.append(contentsOf: persistentApps)
        }

        // 再读取 recent-apps（最近使用的应用）
        if let recentApps = getAppsFromDockPlist(key: "recent-apps") {
            // 添加最近使用的应用（避免重复）
            for app in recentApps {
                if !dockAppsList.contains(where: { $0.1 == app.1 }) {
                    dockAppsList.append(app)
                }
            }
        }

        // 确保 Finder 在列表中（Finder 是程序坞默认应用，可能不在列表中）
        let finderBundleID = "com.apple.finder"
        if !dockAppsList.contains(where: { $0.1 == finderBundleID }) {
            if let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).first,
               let name = finderApp.localizedName {
                dockAppsList.insert((name, finderBundleID), at: 0)
            }
        }

        // 更新缓存
        dockAppsListCache = dockAppsList
        dockAppsListCacheTime = Date()

        Logger.debug("[Dock Plist] 列表已缓存, 总数: \(dockAppsList.count)")
        return dockAppsList
    }

    // 从 Dock 的 plist 读取应用列表
    private func getAppsFromDockPlist(key: String) -> [(String, String)]? {
        var appsList: [(String, String)] = []

        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.dock", key]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            // 先尝试 plist 解析
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
                for appDict in plist {
                    if let tileData = appDict["tile-data"] as? [String: Any],
                       let fileData = tileData["file-data"] as? [String: Any],
                       let urlString = fileData["_CFURLString"] as? String,
                       let url = URL(string: urlString) {

                        let appPath = url.path
                        if appPath.contains(".app") {
                            if let bundle = Bundle(path: appPath),
                               let bundleID = bundle.bundleIdentifier {
                                let appName = url.deletingPathExtension().lastPathComponent
                                appsList.append((appName, bundleID))
                            }
                        }
                    }
                }
            }

            // 如果 plist 解析失败，使用正则表达式
            if appsList.isEmpty, let output = String(data: data, encoding: .utf8) {
                let pattern = "\"_CFURLString\"\\s*=\\s*\"([^\"]+)\""
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(output.startIndex..., in: output)
                    let matches = regex.matches(in: output, range: range)

                    for match in matches {
                        if let urlRange = Range(match.range(at: 1), in: output) {
                            var urlString = String(output[urlRange])
                            urlString = urlString.removingPercentEncoding ?? urlString

                            if let url = URL(string: urlString) {
                                let appPath = url.path
                                if appPath.contains(".app") {
                                    if let bundle = Bundle(path: appPath),
                                       let bundleID = bundle.bundleIdentifier {
                                        let appName = url.deletingPathExtension().lastPathComponent
                                        appsList.append((appName, bundleID))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            // 忽略错误
        }

        return appsList
    }

    // 获取 Dock 的应用顺序
    private func getDockAppOrder() -> [String] {
        // 从 Dock 的 plist 获取应用顺序
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["read", "com.apple.dock", "persistent-apps"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                var bundleIDs: [String] = []

                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    if line.contains("_CFURLString") {
                        if let range = line.range(of: "file://") {
                            let path = String(line[range.upperBound...])
                            if path.contains(".app/") {
                                if let appStart = path.range(of: "/Applications/") {
                                    var appPath = String(path[appStart.upperBound...])
                                    appPath = appPath.replacingOccurrences(of: ".app/", with: "")
                                    appPath = appPath.replacingOccurrences(of: "%20", with: " ")
                                    if !appPath.isEmpty {
                                        bundleIDs.append(appPath)
                                    }
                                }
                            }
                        }
                    }
                }

                if !bundleIDs.isEmpty {
                    Logger.info("📋 Dock apps: \(bundleIDs)")
                    return bundleIDs
                }
            }
        } catch {
            Logger.warning("Failed to read dock apps: \(error)")
        }

        return []
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

    private func startHoverTimer(for iconInfo: DockIconInfo) {
        hoverTimer?.invalidate()

        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hoveredAppBundleID = iconInfo.bundleID
                self?.hoveredIconInfo = iconInfo
            }
        }
    }

    private func startHoverTimer(for bundleID: String) {
        hoverTimer?.invalidate()

        // 如果是同一个应用，尝试保留已有的位置信息
        let currentIconInfo = hoveredIconInfo

        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hoveredAppBundleID = bundleID
                // 如果之前有位置信息且是同一个应用，保留它
                if let info = currentIconInfo, info.bundleID == bundleID {
                    self?.hoveredIconInfo = info
                    Logger.debug("[Dock Timer] 保留位置信息: \(bundleID), center=\(info.center)")
                } else {
                    self?.hoveredIconInfo = nil
                    Logger.debug("[Dock Timer] 无位置信息: \(bundleID)")
                }
            }
        }
    }

    private func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil

        if hoveredAppBundleID != nil {
            DispatchQueue.main.async { [weak self] in
                self?.hoveredAppBundleID = nil
                self?.hoveredIconInfo = nil
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

