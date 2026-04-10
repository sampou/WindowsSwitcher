import AppKit
import SwiftUI
import Carbon
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var switchPanelWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalEscKeyMonitor: Any?  // ESC 键全局监听器
    private let windowManager = WindowManager.shared
    private let previewGenerator = PreviewGenerator()
    private let filterEngine = FilterEngine()
    private let configManager = ConfigManager.shared
    private let hotKeyManager = HotKeyManager()
    private var isPanelVisible = false
    private var lastHotKeyTime: Date = .distantPast
    private var switchPanelViewModel: SwitchPanelViewModel?
    private var dockPreviewWindow: NSWindow?
    private var dockPreviewCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("=== Application starting ===")

        // 确保作为菜单栏应用运行，不显示 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        Logger.info("1. Activation policy set")

        setupMenuBar()
        Logger.info("2. MenuBar setup complete")

        requestPermissions()
        Logger.info("3. Permissions requested")

        setupHotKeys()
        Logger.info("4. HotKeys setup complete")

        // 监听 Option 键释放，当面板显示时自动切换并关闭
        setupOptionKeyMonitor()
        Logger.info("5. Option key monitor setup complete")

        // 启动程序坞预览功能（如果启用）
        Logger.info("6. Calling setupDockPreview...")
        setupDockPreview()
        Logger.info("7. setupDockPreview complete")
    }

    // 启动程序坞预览功能
    private func setupDockPreview() {
        Logger.info(">>> setupDockPreview called")

        // 检查配置是否启用程序坞预览
        guard ConfigManager.shared.config.dockPreview.enabled else {
            Logger.info("Dock preview is DISABLED in config")
            return
        }

        Logger.info("Dock preview is ENABLED, starting...")

        // 启动 DockPreviewManager
        DockPreviewManager.shared.start()
        Logger.info("DockPreviewManager.start() called")

        // 监听预览显示状态变化，创建/隐藏预览窗口
        dockPreviewCancellable = DockPreviewManager.shared.$isPreviewVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                if isVisible {
                    Task { @MainActor in
                        self?.showDockPreviewPanel()
                    }
                } else {
                    Task { @MainActor in
                        self?.hideDockPreviewPanel()
                    }
                }
            }
    }

    // 显示程序坞预览面板 - 复刻切换器样式
    @MainActor
    private func showDockPreviewPanel() {
        guard dockPreviewWindow == nil else {
            return
        }

        // 检查预览项
        let items = DockPreviewManager.shared.previewItems
        guard !items.isEmpty else {
            return
        }

        // 获取配置
        let config = ConfigManager.shared.config.dockPreview
        let previewSize = ConfigManager.shared.config.appearance.previewSize
        let itemWidth = previewSize.itemDimensions.width
        let itemHeight = previewSize.itemDimensions.height
        let itemSpacing: CGFloat = 20

        // 计算面板尺寸
        let itemCount = min(items.count, config.maxPreviewCount)
        let panelPadding: CGFloat = DesignTokens.Panel.padding
        let panelWidth = CGFloat(itemCount) * itemWidth + CGFloat(itemCount - 1) * itemSpacing + panelPadding * 2
        let panelHeight = itemHeight + panelPadding * 2

        // 获取屏幕和 Dock 信息
        let screenFrame = NSScreen.main?.frame ?? .zero
        let dockFrame = DockGeometry.getDockFrame()
        let dockPosition = DockPreviewManager.shared.currentDockPosition

        // 计算面板位置
        // macOS 坐标系：y = 0 在屏幕底部，y = screenFrame.height 在屏幕顶部
        var panelX: CGFloat = screenFrame.midX - panelWidth / 2
        var panelY: CGFloat = 0

        switch dockPosition {
        case .bottom:
            // Dock 在底部：面板显示在 Dock 上方
            panelY = dockFrame.height + 20
        case .top:
            // Dock 在顶部：面板显示在 Dock 下方
            panelY = screenFrame.height - dockFrame.height - panelHeight - 20
        case .left:
            // Dock 在左侧：面板显示在 Dock 右侧
            panelX = dockFrame.width + 20
            panelY = screenFrame.midY - panelHeight / 2
        case .right:
            // Dock 在右侧：面板显示在 Dock 左侧
            panelX = screenFrame.width - dockFrame.width - panelWidth - 20
            panelY = screenFrame.midY - panelHeight / 2
        }

        // 确保面板不超出屏幕边界
        panelX = max(10, min(panelX, screenFrame.width - panelWidth - 10))
        panelY = max(10, min(panelY, screenFrame.height - panelHeight - 10))

        // 创建 SwiftUI 视图
        let dockPreviewView = DockPreviewPanelView(manager: DockPreviewManager.shared) { [weak self] in
            self?.hideDockPreviewPanel()
        }

        // 创建面板
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu  // 使用更高的层级确保显示在最前面
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true

        // 设置 SwiftUI 内容
        let hostingView = NSHostingView(rootView: dockPreviewView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        panel.contentView = hostingView

        // 设置窗口位置
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))

        // 添加淡入动画
        if config.showAnimation {
            panel.alphaValue = 0
            panel.orderFrontRegardless()  // 强制显示在最前面
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }

        dockPreviewWindow = panel
        Logger.info("Dock preview panel shown at (\(panelX), \(panelY)), size: \(panelWidth)x\(panelHeight)")
    }

    // 隐藏程序坞预览面板
    @MainActor
    private func hideDockPreviewPanel() {
        guard let window = dockPreviewWindow else { return }

        let config = ConfigManager.shared.config.dockPreview
        if config.showAnimation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                window.orderOut(nil)
                self?.dockPreviewWindow = nil
            }
        } else {
            window.orderOut(nil)
            dockPreviewWindow = nil
        }
        Logger.info("Dock preview window hidden")
    }

    // 监听 Option 键释放 - 使用全局监听器
    private func setupOptionKeyMonitor() {
        // 使用全局监听器捕获键盘事件（即使面板显示时也能捕获）
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }

            let isOptionPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
            Logger.debug("Global flagsChanged: isOptionPressed=\(isOptionPressed), isPanelVisible=\(self.isPanelVisible)")

            guard self.isPanelVisible else { return }

            // Option 键被释放
            if !isOptionPressed {
                Logger.info("Global: Option key released, calling activateSelectedAndHide()")
                Task { @MainActor in
                    self.activateSelectedAndHide()
                }
            }
        }

        // 同时使用本地监听器作为备份
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }

            let isOptionPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)

            guard self.isPanelVisible else { return event }

            // Option 键被释放
            if !isOptionPressed {
                Logger.info("Local: Option key released, calling activateSelectedAndHide()")
                Task { @MainActor in
                    self.activateSelectedAndHide()
                }
            }
            return event
        }
    }

    /// 激活选中的窗口并隐藏面板（时序优化）
    @MainActor
    private func activateSelectedAndHide() {
        Logger.info("=== activateSelectedAndHide called ===")
        Logger.info("switchPanelViewModel is nil: \(switchPanelViewModel == nil)")

        guard let vm = switchPanelViewModel else {
            Logger.error("switchPanelViewModel is nil! Cannot activate window.")
            hideSwitchPanel()
            return
        }

        // 1. 先获取要激活的窗口信息
        Logger.info("filteredWindows count: \(vm.filteredWindows.count)")
        Logger.info("selectedIndex: \(vm.selectedIndex)")

        guard let selectedWindow = vm.selectedWindow else {
            Logger.warning("No selected window to activate (selectedWindow is nil)")
            hideSwitchPanel()
            return
        }

        Logger.info("Selected window: \(selectedWindow.appName) - PID:\(selectedWindow.ownerPID), Title: \(selectedWindow.windowTitle)")

        // 2. 先隐藏面板（这样面板就不会阻挡焦点转移）
        hideSwitchPanel()

        // 3. 直接使用 WindowManager.shared 激活窗口（确保使用最新数据）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            // 刷新窗口列表确保获取最新的窗口信息
            let freshWindows = self?.windowManager.getAllWindows() ?? []
            if let freshWindow = freshWindows.first(where: { $0.id == selectedWindow.id }) {
                self?.windowManager.activateWindow(freshWindow)
                Logger.info("Activated fresh window: \(freshWindow.appName)")
            } else {
                // 如果找不到匹配的窗口，使用原始窗口信息
                self?.windowManager.activateWindow(selectedWindow)
                Logger.info("Activated original window: \(selectedWindow.appName)")
            }

            // 4. 强制激活目标应用（确保焦点转移到目标窗口）
            if let app = NSRunningApplication(processIdentifier: selectedWindow.ownerPID) {
                app.activate(options: .activateIgnoringOtherApps)
                Logger.info("App activated: \(app.localizedName ?? "unknown")")
            }
        }
    }

    // MARK: - 快捷键注册
    private func setupHotKeys() {
        // Option+Tab: 显示/下一个
        hotKeyManager.register(
            HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), identifier: "switch")
        ) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            Logger.info("=== Option+Tab pressed ===")
            // 移除节流限制，允许最快速度切换
            let now = Date()
            guard now.timeIntervalSince(self.lastHotKeyTime) > 0.005 else { return }  // 5ms 节流
            self.lastHotKeyTime = now
            DispatchQueue.main.async { [weak self] in
                let t1 = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                Logger.info("=== hotkey dispatch delay: \(t1)ms ===")
                guard let self else { return }
                if self.isPanelVisible {
                    Logger.info("--> Panel visible, switching to next")
                    let t2 = CFAbsoluteTimeGetCurrent()
                    NotificationCenter.default.post(name: .switchHotKeyPressed, object: nil)
                    Logger.info("=== notification post took: \((CFAbsoluteTimeGetCurrent() - t2)*1000)ms ===")
                } else {
                    Logger.info("--> Panel hidden, showing panel")
                    Task { @MainActor in self.showSwitchPanel() }
                }
            }
        }

        // Option+Shift+Tab: 反向切换
        hotKeyManager.register(
            HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey), identifier: "reverseSwitch")
        ) { [weak self] in
            guard let self else { return }
            Logger.info("=== Option+Shift+Tab pressed ===")
            // 快速切换：20ms 延迟（从100ms减少，大幅提升切换速度）
            let now = Date()
            guard now.timeIntervalSince(self.lastHotKeyTime) > 0.02 else { return }
            self.lastHotKeyTime = now
            DispatchQueue.main.async {
                if self.isPanelVisible {
                    NotificationCenter.default.post(name: .reverseSwitchHotKeyPressed, object: nil)
                } else {
                    Task { @MainActor in self.showSwitchPanel(reversed: true) }
                }
            }
        }

        // Option+`: 应用内切换
        hotKeyManager.register(
            HotKey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey), identifier: "appSwitch")
        ) {
            NotificationCenter.default.post(name: .appSwitchHotKeyPressed, object: nil)
        }
    }

    // MARK: - 菜单栏
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Window Switcher")
            // 左键单击直接显示切换面板
            button.action = #selector(statusBarButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @MainActor @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            let showItem = NSMenuItem(title: "显示切换器", action: #selector(showSwitcherFromMenu), keyEquivalent: "")
            showItem.target = self
            let settingsItem = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ",")
            settingsItem.target = self
            let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(showItem)
            menu.addItem(settingsItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(quitItem)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            showSwitchPanel()
        }
    }

    @objc private func showSwitcherFromMenu() {
        Task { @MainActor in self.showSwitchPanel() }
    }

    private func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let hasTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        let hasScreen = CGPreflightScreenCaptureAccess()

        if !hasScreen {
            // 请求屏幕录制权限
            CGRequestScreenCaptureAccess()
            // 提示用户手动开启
            showPermissionAlert(for: "屏幕录制")
        }

        if !hasTrusted {
            showPermissionAlert(for: "辅助功能")
        }

        if !hasTrusted || !hasScreen {
            updateMenuBarIcon(hasPermissions: false)
            Logger.warning("Missing permissions - Accessibility: \(hasTrusted), Screen Recording: \(hasScreen)")
        } else {
            updateMenuBarIcon(hasPermissions: true)
            Logger.info("All permissions granted")
        }
    }

    private func showPermissionAlert(for permission: String) {
        let alert = NSAlert()
        alert.messageText = "需要\(permission)权限"
        alert.informativeText = "WindowsSwitcher 需要\(permission)权限来显示窗口预览。请在系统设置中开启该权限。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacySettings()
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateMenuBarIcon(hasPermissions: Bool) {
        let iconName = hasPermissions ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash"
        statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    }

    @objc private func openSettings() {
        // 手动创建并显示设置窗口，不依赖 SwiftUI Settings 场景
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "WindowsSwitcher 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 420))
        window.center()

        // 确保应用激活
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 切换面板
    @MainActor
    func showSwitchPanel(reversed: Bool = false) {
        Logger.info("==> showSwitchPanel START")
        let startTime = CFAbsoluteTimeGetCurrent()

        // 在显示面板前先记录当前前台应用（因为显示面板后 frontmostApplication 会变成我们的面板）
        let previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        let previousPID = previousFrontmostApp?.processIdentifier
        let previousBundleID = previousFrontmostApp?.bundleIdentifier
        Logger.info("==> Previous frontmost app: \(previousBundleID ?? "unknown"), PID: \(previousPID ?? -1)")

        guard !isPanelVisible else { return }
        isPanelVisible = true

        // 1. 先监听窗口变化，以便实时更新活跃时间
        windowManager.observeWindowChanges { [weak self] event in
            Task { @MainActor in
                switch event {
                case .windowStateChanged(let window):
                    Logger.debug("Window state changed: \(window.appName)")
                    // 窗口状态变化时刷新列表
                    self?.switchPanelViewModel?.refreshWindows()
                default:
                    break
                }
            }
        }

        // 2. 实时获取所有窗口（包含最新的活跃时间）
        let t0 = CFAbsoluteTimeGetCurrent()
        var windows = windowManager.getAllWindows()
        Logger.info("==> getAllWindows: \((CFAbsoluteTimeGetCurrent() - t0)*1000)ms, count: \(windows.count)")

        // 3. 在获取窗口后，立即更新当前前台窗口的 lastActiveTime
        // 因为 previousPID 已经被切换成 WindowsSwitcher 自己了
        let now = Date()
        if let frontmostApp = NSWorkspace.shared.frontmostApplication,
           frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            let frontmostPID = frontmostApp.processIdentifier
            Logger.info("==> Current frontmost app: \(frontmostApp.localizedName ?? "unknown"), PID: \(frontmostPID)")

            // 找到该应用的所有窗口，更新最早活跃的那个（通常是用户正在使用的）
            var maxTime: Date = .distantPast
            var maxIndex: Int = -1
            for (index, window) in windows.enumerated() where window.ownerPID == frontmostPID {
                if window.lastActiveTime > maxTime {
                    maxTime = window.lastActiveTime
                    maxIndex = index
                }
            }

            // 更新最前台的窗口
            if maxIndex >= 0 {
                let updatedWindow = WindowModel(
                    id: windows[maxIndex].id,
                    appName: windows[maxIndex].appName,
                    bundleIdentifier: windows[maxIndex].bundleIdentifier,
                    windowTitle: windows[maxIndex].windowTitle,
                    appIcon: windows[maxIndex].appIcon,
                    frame: windows[maxIndex].frame,
                    isMinimized: windows[maxIndex].isMinimized,
                    isHidden: windows[maxIndex].isHidden,
                    isOnScreen: windows[maxIndex].isOnScreen,
                    lastActiveTime: now,  // 更新为当前时间
                    windowLayer: windows[maxIndex].windowLayer,
                    ownerPID: windows[maxIndex].ownerPID
                )
                windows[maxIndex] = updatedWindow
                Logger.info("==> Updated frontmost window lastActiveTime: \(updatedWindow.windowTitle)")
            }
        }

        // 4. 按最近活跃时间排序
        let t1 = CFAbsoluteTimeGetCurrent()

        // 检查是否所有窗口的 lastActiveTime 都相同（首次运行或刚重启）
        let firstWindowTime = windows.first?.lastActiveTime ?? Date()
        let allSameTime = windows.allSatisfy { $0.lastActiveTime == firstWindowTime }

        let sortedWindows: [WindowModel]
        if allSameTime {
            // 首次运行时：直接按 windowID 降序排序
            sortedWindows = windows.sorted { w1, w2 in
                w1.id > w2.id
            }
            Logger.debug("==> All windows have same lastActiveTime, using windowID for sorting")
        } else {
            // 按 lastActiveTime 降序排序（最前台的窗口已经在之前更新为 now，会排在最前面）
            sortedWindows = windows.sorted { w1, w2 in
                if w1.lastActiveTime != w2.lastActiveTime {
                    return w1.lastActiveTime > w2.lastActiveTime
                }
                // 如果时间相同，按 windowID 降序排序
                return w1.id > w2.id
            }
        }

        // 打印排序结果日志
        let first3 = sortedWindows.prefix(3).map { "\($0.appName):\($0.lastActiveTime.timeIntervalSinceNow)s" }
        Logger.info("==> sort result, first3: \(first3)")
        Logger.info("==> sort windows: \((CFAbsoluteTimeGetCurrent() - t1)*1000)ms")

        let t2 = CFAbsoluteTimeGetCurrent()
        let vm = SwitchPanelViewModel(
            windows: sortedWindows,
            windowManager: windowManager,
            previewGenerator: previewGenerator,
            filterEngine: filterEngine
        )
        Logger.info("==> SwitchPanelViewModel created: \((CFAbsoluteTimeGetCurrent() - t2)*1000)ms")
        if reversed {
            vm.selectPrevious()
        } else if ConfigManager.shared.config.behavior.defaultSelectSecond && sortedWindows.count > 1 {
            // 如果启用了"默认选中第二个窗口"选项，且窗口数量大于1
            vm.selectedIndex = 1
            Logger.info("==> defaultSelectSecond enabled, selecting index 1")
        }

        // 保存 viewModel 引用，用于 Option 键释放时激活窗口
        self.switchPanelViewModel = vm

        // 4. 启动定时器定期刷新窗口列表（实时更新）
        startWindowRefreshTimer(for: vm)

        let t3 = CFAbsoluteTimeGetCurrent()
        let view = SwitchPanelView(viewModel: vm) { [weak self] in
            self?.hideSwitchPanel()
        }
        Logger.info("==> SwitchPanelView created: \((CFAbsoluteTimeGetCurrent() - t3)*1000)ms")

        // 创建面板，使用较大尺寸以适应不同预览大小
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // 先创建 hostingView 并添加到面板
        let hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // 计算面板尺寸（与 SwitchPanelView 中的逻辑一致）
        let previewSize = ConfigManager.shared.config.appearance.previewSize
        let itemWidth = previewSize.itemDimensions.width
        let itemHeight = previewSize.itemDimensions.height

        // 计算 columnCount（与 SwitchPanelView 保持一致）
        let columnCount: Int
        if ConfigManager.shared.config.appearance.switcherColumns > 0 {
            columnCount = ConfigManager.shared.config.appearance.switcherColumns
        } else {
            let maxPanelWidth: CGFloat = 1400
            columnCount = max(3, min(8, Int((maxPanelWidth - DesignTokens.Panel.padding * 2) / (itemWidth + 16))))
        }

        let rowCount = max(1, (sortedWindows.count + columnCount - 1) / columnCount)

        // 获取屏幕尺寸
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let desiredSpacing: CGFloat = 16
        let panelPadding: CGFloat = 12
        let bottomBarHeight: CGFloat = 40

        // 计算宽度（屏幕宽度的90%）
        let minWidth: CGFloat = 500
        let maxWidth = screenSize.width * 0.9
        let contentWidth = CGFloat(columnCount) * (itemWidth + desiredSpacing) - desiredSpacing + panelPadding * 2
        let panelWidth = min(max(contentWidth, minWidth), maxWidth)

        // 计算高度（屏幕高度的80%，与 SwitchPanelView 保持一致）
        let minHeight: CGFloat = 400
        let maxHeight = screenSize.height * 0.8
        let contentHeight = CGFloat(rowCount) * (itemHeight + 16) + panelPadding * 2 + bottomBarHeight
        let panelHeight = min(max(contentHeight, minHeight), maxHeight)

        // 设置面板大小
        let newSize = NSSize(width: panelWidth, height: panelHeight)
        panel.setContentSize(newSize)

        // 手动计算居中位置
        if let screen = NSScreen.main {
            // 使用屏幕完整 frame（不包括 Dock 和菜单栏）
            let screenFrame = screen.frame
            // 计算居中位置（macOS Y 坐标从底部开始）
            let x = (screenFrame.width - panelWidth) / 2
            let y = (screenFrame.height - panelHeight) / 2
            Logger.info("==> Panel position: x=\(x), y=\(y), screenFrame=\(screenFrame), panelSize=\(newSize)")
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        PanelAnimator.show(panel)
        switchPanelWindow = panel

        // 设置 ESC 键全局监听器
        setupEscKeyMonitor()

        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("==> showSwitchPanel TOTAL: \(totalTime)ms, \(sortedWindows.count) windows")

        // 批量预加载所有窗口缩略图
        preloadAllPreviews(windows: sortedWindows, viewModel: vm)
    }

    // 批量预加载所有窗口缩略图
    private func preloadAllPreviews(windows: [WindowModel], viewModel: SwitchPanelViewModel) {
        let sizeConfig = ConfigManager.shared.config.appearance.previewSize.dimensions
        let previewSize = CGSize(width: sizeConfig.width, height: sizeConfig.height)

        // 并发批量生成所有缩略图
        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            let previewImages = await previewGenerator.generatePreviews(for: windows, size: previewSize)

            await MainActor.run {
                // 将生成的缩略图存入 ViewModel
                for (windowID, image) in previewImages {
                    viewModel.previewImages[windowID] = image
                }
                Logger.info("==> Preloaded \(previewImages.count) previews in \((CFAbsoluteTimeGetCurrent() - startTime)*1000)ms")
            }
        }
    }

    // 设置 ESC 键全局监听器
    private func setupEscKeyMonitor() {
        // 先移除旧的监听器
        removeEscKeyMonitor()

        Logger.info("==> Setting up ESC and arrow key monitor")

        // 使用全局监听器监听所有键盘事件
        globalEscKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            Logger.info("==> Global keyDown: keyCode=\(event.keyCode), isPanelVisible=\(self.isPanelVisible)")

            guard self.isPanelVisible else { return }

            // ESC 键的 keyCode 是 53
            if event.keyCode == 53 {
                Logger.info("==> Global ESC pressed, hiding panel")
                Task { @MainActor in
                    self.hideSwitchPanel()
                }
                return
            }

            // 处理方向键
            guard let vm = self.switchPanelViewModel else { return }
            switch event.specialKey {
            case .leftArrow:
                Logger.debug("==> Global left arrow")
                Task { @MainActor in
                    vm.selectPrevious()
                }
            case .rightArrow:
                Logger.debug("==> Global right arrow")
                Task { @MainActor in
                    vm.selectNext()
                }
            case .upArrow:
                Logger.debug("==> Global up arrow")
                Task { @MainActor in
                    vm.selectUp()
                }
            case .downArrow:
                Logger.debug("==> Global down arrow")
                Task { @MainActor in
                    vm.selectDown()
                }
            default:
                break
            }
        }

        if globalEscKeyMonitor != nil {
            Logger.info("==> ESC and arrow key monitor created successfully")
        } else {
            Logger.warning("==> Failed to create ESC key monitor")
        }

        // 同时使用本地监听器
        setupLocalEscKeyMonitor()
    }

    // 设置本地 ESC 键监听器
    private var localEscKeyMonitor: Any?

    private func setupLocalEscKeyMonitor() {
        // 移除旧的本地监听器
        if let monitor = localEscKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localEscKeyMonitor = nil
        }

        localEscKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            Logger.info("==> Local keyDown: keyCode=\(event.keyCode), isPanelVisible=\(self.isPanelVisible)")

            guard self.isPanelVisible else { return event }

            // ESC 键的 keyCode 是 53
            if event.keyCode == 53 {
                Logger.info("==> Local ESC pressed, hiding panel")
                Task { @MainActor in
                    self.hideSwitchPanel()
                }
                return nil // 阻止事件继续传递
            }

            // 处理方向键
            guard let vm = self.switchPanelViewModel else { return event }
            switch event.specialKey {
            case .leftArrow:
                Task { @MainActor in
                    vm.selectPrevious()
                }
            case .rightArrow:
                Task { @MainActor in
                    vm.selectNext()
                }
            case .upArrow:
                Task { @MainActor in
                    vm.selectUp()
                }
            case .downArrow:
                Task { @MainActor in
                    vm.selectDown()
                }
            default:
                return event
            }
            return nil // 阻止方向键事件继续传递
        }

        if localEscKeyMonitor != nil {
            Logger.info("==> Local ESC key monitor created successfully")
        }
    }

    // 移除 ESC 键监听器
    private func removeEscKeyMonitor() {
        if let monitor = globalEscKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscKeyMonitor = nil
        }
        if let monitor = localEscKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localEscKeyMonitor = nil
        }
    }

    // 定时刷新窗口列表 - 已禁用，避免快速切换时产生卡顿
    private var windowRefreshTimer: Timer?

    private func startWindowRefreshTimer(for vm: SwitchPanelViewModel) {
        // 已禁用：不再定期刷新窗口列表，避免影响切换流畅度
        // 窗口列表会在下次显示面板时自动刷新
    }

    private func stopWindowRefreshTimer() {
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil
    }

    func hideSwitchPanel() {
        // 停止刷新定时器
        stopWindowRefreshTimer()

        // 移除 ESC 键监听器
        removeEscKeyMonitor()

        guard let panel = switchPanelWindow else { return }
        PanelAnimator.hide(panel) { [weak self] in
            self?.switchPanelWindow = nil
            self?.isPanelVisible = false
            Logger.info("Switch panel hidden")
        }
    }
}
