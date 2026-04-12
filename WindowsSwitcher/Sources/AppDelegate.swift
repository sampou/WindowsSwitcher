import AppKit
import SwiftUI
import Carbon
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var switchPanelWindow: NSWindow?
    private var settingsWindow: NSWindow?  // 设置窗口引用
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
    private var selectedWindowCancellable: AnyCancellable?  // 监听选中窗口变化

    // 标记是否已完成延迟初始化
    private var deferredInitCompleted = false
    private var dockPreviewConfigCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let startTime = CFAbsoluteTimeGetCurrent()
        Logger.info("=== Application starting ===")

        // === 第一阶段：核心初始化（必须同步完成）===

        // 确保作为菜单栏应用运行，不显示 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        Logger.info("1. Activation policy set")

        // 同步开机启动状态
        LaunchAtLoginManager.shared.syncStatus()
        Logger.info("2. Launch at login synced")

        // 设置菜单栏
        setupMenuBar()
        Logger.info("3. MenuBar setup complete")

        // 禁用系统 Command+Tab 快捷键（需要辅助功能权限）
        disableSystemHotKeysIfNeeded()

        // 注册信号处理器，捕获异常退出并恢复系统快捷键
        setupSignalHandlers()

        // 注册退出处理器，确保应用退出时恢复系统快捷键
        atexit_b {
            restoreAllSystemHotKeys()
        }

        let coreInitTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("=== Core init completed in \(coreInitTime)ms ===")

        // === 第二阶段：自动显示设置界面 ===
        showSettingsOnLaunch()

        // === 第三阶段：延迟初始化（非必要组件，后台执行）===
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performDeferredInitialization()
        }
    }

    /// 延迟初始化：加载非必要组件
    private func performDeferredInitialization() {
        guard !deferredInitCompleted else { return }
        deferredInitCompleted = true

        Logger.info("=== Starting deferred initialization ===")

        // 请求权限
        requestPermissions()
        Logger.info("4. Permissions requested")

        // 设置快捷键
        setupHotKeys()
        Logger.info("5. HotKeys setup complete")

        // 监听快捷键配置变化
        setupHotKeyChangeListener()
        Logger.info("5.1 HotKey change listener setup complete")

        // 监听 Option 键释放
        setupOptionKeyMonitor()
        Logger.info("6. Option key monitor setup complete")

        // 启动程序坞预览功能
        Logger.info("7. Calling setupDockPreview...")
        setupDockPreview()
        Logger.info("8. setupDockPreview complete")

        Logger.info("=== Deferred initialization completed ===")
    }

    /// 启动时自动显示设置界面
    private func showSettingsOnLaunch() {
        // 显示设置窗口
        DispatchQueue.main.async {
            self.openSettings()
        }
    }

    // 检查权限并禁用系统快捷键
    private func disableSystemHotKeysIfNeeded() {
        let hasTrusted = AXIsProcessTrusted()
        if hasTrusted {
            Logger.info("Accessibility permission granted, disabling system Command+Tab")
            disableAllSystemHotKeys()
        } else {
            Logger.warning("Accessibility permission not granted, cannot disable system Command+Tab")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("=== Application terminating, restoring system hot keys ===")
        // 恢复系统快捷键
        restoreAllSystemHotKeys()
    }

    // 设置信号处理器，捕获异常退出信号并恢复系统快捷键
    private func setupSignalHandlers() {
        // 捕获 SIGTERM（优雅终止，如 kill -15）
        signal(SIGTERM) { _ in
            restoreAllSystemHotKeys()
            Logger.info("=== Caught SIGTERM, restored system hot keys ===")
            exit(0)
        }

        // 捕获 SIGINT（Ctrl+C 终止）
        signal(SIGINT) { _ in
            restoreAllSystemHotKeys()
            Logger.info("=== Caught SIGINT, restored system hot keys ===")
            exit(0)
        }

        // 捕获 SIGHUP（终端关闭）
        signal(SIGHUP) { _ in
            restoreAllSystemHotKeys()
            Logger.info("=== Caught SIGHUP, restored system hot keys ===")
            exit(0)
        }

        Logger.info("Signal handlers registered for cleanup on异常 exit")
    }

    // 启动程序坞预览功能
    private func setupDockPreview() {
        Logger.info(">>> setupDockPreview called")

        // 监听配置变化，动态启动/停止程序坞预览
        dockPreviewConfigCancellable = ConfigManager.shared.$config
            .map(\.dockPreview.enabled)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.startDockPreview()
                } else {
                    self?.stopDockPreview()
                }
            }

        // 初始状态
        if ConfigManager.shared.config.dockPreview.enabled {
            startDockPreview()
        }
    }

    /// 启动程序坞预览
    private func startDockPreview() {
        Logger.info(">>> Starting Dock Preview...")

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

    /// 停止程序坞预览
    private func stopDockPreview() {
        Logger.info(">>> Stopping Dock Preview...")

        // 停止 DockPreviewManager
        DockPreviewManager.shared.stop()
        Logger.info("DockPreviewManager.stop() called")

        // 取消监听
        dockPreviewCancellable?.cancel()
        dockPreviewCancellable = nil

        // 隐藏预览窗口（在主线程）
        Task { @MainActor in
            self.hideDockPreviewPanel()
        }
    }

    // 显示程序坞预览面板 - 精确定位在图标上方
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
        let panelPadding: CGFloat = DesignTokens.Panel.padding

        // 计算行数和列数
        let maxItemsPerRow = config.maxPreviewCount
        let totalItems = items.count
        let rows = (totalItems + maxItemsPerRow - 1) / maxItemsPerRow
        let displayRows = min(rows, 3)  // 最多显示3行，超过需滚动

        // 自适应宽度计算：根据实际显示的列数计算宽度
        // 使用实际第一行显示的数量，但最少显示1列
        let actualColumns = min(totalItems, maxItemsPerRow)
        let panelWidth = CGFloat(actualColumns) * itemWidth + CGFloat(actualColumns - 1) * itemSpacing + panelPadding * 2

        // 滚动提示高度
        let scrollIndicatorHeight: CGFloat = rows > 3 ? 24 : 0

        // 自适应高度计算：根据实际显示的行数计算高度
        let panelHeight: CGFloat
        if rows <= 3 {
            // 不需要滚动，高度 = 行数 * 项目高度 + (行数-1) * 间距 + 内边距 * 2 + 滚动指示器
            panelHeight = CGFloat(displayRows) * itemHeight + CGFloat(displayRows - 1) * itemSpacing + panelPadding * 2 + scrollIndicatorHeight
        } else {
            // 需要滚动，固定高度显示3行
            panelHeight = 3 * itemHeight + 2 * itemSpacing + panelPadding * 2 + scrollIndicatorHeight
        }

        // 获取屏幕信息
        let screenFrame = NSScreen.main?.frame ?? .zero
        let dockPosition = DockPreviewManager.shared.currentDockPosition
        let dockFrame = DockGeometry.getDockFrame()

        // 获取智能间距（如果用户设置了自定义值则使用自定义值，否则使用系统推荐的智能间距）
        let recommendedSpacing = DockGeometry.getRecommendedSpacing()
        let verticalSpacing = config.verticalSpacing > 0 ? CGFloat(config.verticalSpacing) : recommendedSpacing.vertical
        let horizontalSpacing = config.horizontalSpacing > 0 ? CGFloat(config.horizontalSpacing) : recommendedSpacing.horizontal

        // 计算面板位置
        var panelX: CGFloat
        var panelY: CGFloat

        // 同步获取图标中心位置（避免 Combine 发布延迟问题）
        if let iconCenter = DockPreviewManager.shared.getCurrentIconCenter() {
            // 精确模式：面板水平居中于图标
            panelX = iconCenter.x - panelWidth / 2
            Logger.debug("[Dock定位] 精确模式: iconCenter=\(iconCenter), panelWidth=\(panelWidth), panelX=\(panelX)")

            switch dockPosition {
            case .bottom:
                // Dock 在底部：面板底部边缘与 Dock 顶部边缘保持间距
                // iconCenter.y 是图标中心的 Y 坐标，图标在 Dock 内
                // 面板底部应该在 Dock 顶部上方 verticalSpacing 像素
                panelY = dockFrame.height + verticalSpacing
            case .top:
                // Dock 在顶部：面板顶部边缘与 Dock 底部边缘保持间距
                panelY = screenFrame.height - dockFrame.height - panelHeight - verticalSpacing
            case .left:
                // Dock 在左侧：面板左边缘与 Dock 右边缘保持间距
                panelX = dockFrame.width + horizontalSpacing
                panelY = iconCenter.y - panelHeight / 2
            case .right:
                // Dock 在右侧：面板右边缘与 Dock 左边缘保持间距
                panelX = screenFrame.width - dockFrame.width - panelWidth - horizontalSpacing
                panelY = iconCenter.y - panelHeight / 2
            }
        } else {
            // 降级模式：使用 Dock frame 计算位置
            panelX = screenFrame.midX - panelWidth / 2

            switch dockPosition {
            case .bottom:
                panelY = dockFrame.height + verticalSpacing
            case .top:
                panelY = screenFrame.height - dockFrame.height - panelHeight - verticalSpacing
            case .left:
                panelX = dockFrame.width + horizontalSpacing
                panelY = screenFrame.midY - panelHeight / 2
            case .right:
                panelX = screenFrame.width - dockFrame.width - panelWidth - horizontalSpacing
                panelY = screenFrame.midY - panelHeight / 2
            }
        }

        // 确保面板不超出屏幕边界（跨分辨率适配）
        // 注意：需要确保不会把面板拉回到覆盖 Dock 的位置
        switch dockPosition {
        case .bottom:
            // Dock 在底部：确保面板底部不低于 Dock 顶部 + 计算的间距
            let minY = dockFrame.height + verticalSpacing
            panelX = max(5, min(panelX, screenFrame.width - panelWidth - 5))
            panelY = max(minY, min(panelY, screenFrame.height - panelHeight - 5))
        case .top:
            // Dock 在顶部：确保面板顶部不高于 Dock 底部 + 计算的间距
            let maxY = screenFrame.height - dockFrame.height - verticalSpacing - panelHeight
            panelX = max(5, min(panelX, screenFrame.width - panelWidth - 5))
            panelY = max(5, min(panelY, maxY))
        case .left:
            // Dock 在左侧：确保面板左边缘不低于 Dock 右边缘 + 计算的间距
            let minX = dockFrame.width + horizontalSpacing
            panelX = max(minX, min(panelX, screenFrame.width - panelWidth - 5))
            panelY = max(5, min(panelY, screenFrame.height - panelHeight - 5))
        case .right:
            // Dock 在右侧：确保面板右边缘不高于 Dock 左边缘 + 计算的间距
            let maxX = screenFrame.width - dockFrame.width - horizontalSpacing - panelWidth
            panelX = max(5, min(panelX, maxX))
            panelY = max(5, min(panelY, screenFrame.height - panelHeight - 5))
        }

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
        panel.level = .popUpMenu  // 高显示层级
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

        // 更新预览窗口 frame 到 DockPreviewManager（用于鼠标位置检测）
        let panelFrame = CGRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        DockPreviewManager.shared.updatePreviewWindowFrame(panelFrame)

        // 添加淡入动画（200-300ms 平滑过渡）
        if config.showAnimation {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2  // 200ms 动画
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }

        dockPreviewWindow = panel
    }

    // 隐藏程序坞预览面板
    @MainActor
    private func hideDockPreviewPanel() {
        guard let window = dockPreviewWindow else { return }

        let config = ConfigManager.shared.config.dockPreview
        if config.showAnimation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08  // 缩短动画时间
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                window.orderOut(nil)
                Task { @MainActor in
                    self?.dockPreviewWindow = nil
                }
            }
        } else {
            window.orderOut(nil)
            dockPreviewWindow = nil
        }
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
        // 从配置读取快捷键设置
        let hotKeyConfig = configManager.config.hotKeys

        // 注销所有旧快捷键
        hotKeyManager.unregister("switch")
        hotKeyManager.unregister("reverseSwitch")
        hotKeyManager.unregister("appSwitch")
        hotKeyManager.unregister("appSwitchReverse")

        // 切换器快捷键（可自定义）
        let switchKeyCode = hotKeyConfig.switchKeyCode
        let switchModifiers = hotKeyConfig.switchModifiers

        // 注册切换器快捷键：显示/下一个
        hotKeyManager.register(
            HotKey(keyCode: switchKeyCode, modifiers: switchModifiers, identifier: "switch")
        ) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            Logger.info("=== Switch hotkey pressed ===")
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

        // 反向切换：Shift + 切换器快捷键
        hotKeyManager.register(
            HotKey(keyCode: switchKeyCode, modifiers: switchModifiers | UInt32(shiftKey), identifier: "reverseSwitch")
        ) { [weak self] in
            guard let self else { return }
            Logger.info("=== Reverse switch hotkey pressed ===")
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

        // 应用内切换快捷键（可自定义，可禁用）
        let appSwitchKeyCode = hotKeyConfig.appSwitchKeyCode
        let appSwitchModifiers = hotKeyConfig.appSwitchModifiers
        let appSwitchReverseModifiers = hotKeyConfig.appSwitchReverseModifiers
        let appSwitchEnabled = hotKeyConfig.appSwitchEnabled

        if appSwitchEnabled {
            // 正向切换：Option+`
            hotKeyManager.register(
                HotKey(keyCode: appSwitchKeyCode, modifiers: appSwitchModifiers, identifier: "appSwitch")
            ) { [weak self] in
                guard let self else { return }
                Logger.info("=== AppSwitch hotkey pressed ===")
                DispatchQueue.main.async {
                    if self.isPanelVisible {
                        // 面板已显示，在当前应用内切换窗口
                        NotificationCenter.default.post(name: .appSwitchHotKeyPressed, object: nil)
                    } else {
                        // 面板未显示，显示面板并筛选当前应用的窗口
                        Task { @MainActor in self.showSwitchPanel(appSwitchMode: true) }
                    }
                }
            }

            // 反向切换：Option+Shift+`
            let appSwitchReverseKeyCode = hotKeyConfig.appSwitchReverseKeyCode
            let appSwitchReverseModifiers = hotKeyConfig.appSwitchReverseModifiers
            hotKeyManager.register(
                HotKey(keyCode: appSwitchReverseKeyCode, modifiers: appSwitchReverseModifiers, identifier: "appSwitchReverse")
            ) { [weak self] in
                guard let self else { return }
                Logger.info("=== AppSwitch Reverse hotkey pressed ===")
                DispatchQueue.main.async {
                    if self.isPanelVisible {
                        // 面板已显示，反向切换当前应用的窗口
                        NotificationCenter.default.post(name: .appSwitchReverseHotKeyPressed, object: nil)
                    } else {
                        // 面板未显示，显示面板并筛选当前应用的窗口（反向）
                        Task { @MainActor in self.showSwitchPanel(reversed: true, appSwitchMode: true) }
                    }
                }
            }

            Logger.info("HotKeys registered: switch=\(HotKeyFormatter.format(keyCode: switchKeyCode, modifiers: switchModifiers)), appSwitch=\(HotKeyFormatter.format(keyCode: appSwitchKeyCode, modifiers: appSwitchModifiers)), appSwitchReverse=\(HotKeyFormatter.format(keyCode: appSwitchKeyCode, modifiers: appSwitchReverseModifiers))")
        } else {
            Logger.info("HotKeys registered: switch=\(HotKeyFormatter.format(keyCode: switchKeyCode, modifiers: switchModifiers)), appSwitch=DISABLED")
        }
    }

    // MARK: - 快捷键变化监听
    private var hotKeyChangeObserver: NSObjectProtocol?

    private func setupHotKeyChangeListener() {
        // 监听快捷键配置变化
        hotKeyChangeObserver = NotificationCenter.default.addObserver(
            forName: .hotKeysDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.info("=== HotKeys config changed, re-registering ===")
            self?.setupHotKeys()
        }
    }

    // MARK: - 菜单栏
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            // 使用自定义图标，与应用图标风格一致
            button.image = loadStatusBarIcon()
            // 左键单击直接显示切换面板
            button.action = #selector(statusBarButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    /// 加载状态栏图标
    private func loadStatusBarIcon() -> NSImage? {
        // 使用应用图标作为状态栏图标
        if let image = NSImage(named: "AppIcon") {
            let resizedImage = NSImage(size: NSSize(width: 18, height: 18))
            resizedImage.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            resizedImage.unlockFocus()
            // 不设置为模板图像，保持原图标彩色样式
            return resizedImage
        }
        // 降级到 SF Symbols
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Window Switcher")
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
        if let image = loadStatusBarIcon() {
            // 权限缺失时降低透明度
            statusItem?.button?.alphaValue = hasPermissions ? 1.0 : 0.5
            statusItem?.button?.image = image
        }
    }

    @objc private func openSettings() {
        // 如果设置窗口已存在，直接激活
        if let existingWindow = settingsWindow {
            NSApp.setActivationPolicy(.regular)  // 确保 Dock 图标显示
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 计算响应式窗口尺寸
        let windowSize = ResponsiveSize.settingsWindowSize()
        let minSize = ResponsiveSize.minWindowSize

        // 手动创建并显示设置窗口，不依赖 SwiftUI Settings 场景
        // SettingsView 内部已通过 @ObservedObject 监听 ThemeManager，自动响应主题变化
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "WindowsSwitcher 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(windowSize)
        window.minSize = minSize
        window.center()
        window.delegate = self  // 设置代理以监听窗口关闭事件
        window.isReleasedWhenClosed = false  // 防止窗口关闭时被释放

        // 保存窗口引用
        settingsWindow = window

        // 确保应用激活并显示 Dock 图标
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // 检查是否是设置窗口关闭
        if window === settingsWindow {
            // 切换回 accessory 模式，移除 Dock 图标
            NSApp.setActivationPolicy(.accessory)
            Logger.info("设置窗口已关闭，切换回 accessory 模式")
        }
    }

    // MARK: - 切换面板
    @MainActor
    func showSwitchPanel(reversed: Bool = false, appSwitchMode: Bool = false) {
        Logger.info("==> showSwitchPanel START (reversed=\(reversed), appSwitchMode=\(appSwitchMode))")
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

        // 3. 如果是 appSwitchMode，只保留当前应用的窗口
        if appSwitchMode, let currentApp = previousFrontmostApp?.localizedName {
            windows = windows.filter { $0.appName == currentApp }
            Logger.info("==> AppSwitchMode: filtered to \(windows.count) windows for \(currentApp)")
        }

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

        // 选中逻辑
        if reversed {
            vm.selectPrevious()
        } else if appSwitchMode && sortedWindows.count > 1 {
            // 同应用切换模式：默认选中第二个窗口（下一个要切换的窗口）
            vm.selectedIndex = 1
            Logger.info("==> AppSwitchMode: selecting index 1 (next window)")
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
        panel.level = .popUpMenu  // 使用 popUpMenu 层级，比 floating 更高
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

        // 计算面板尺寸 - 自适应内容
        let previewSize = ConfigManager.shared.config.appearance.previewSize
        let itemWidth = previewSize.itemDimensions.width
        let itemHeight = previewSize.itemDimensions.height

        // 自适应列数：根据窗口数量动态计算
        let windowCount = sortedWindows.count
        let desiredSpacing: CGFloat = 16
        let panelPadding: CGFloat = 8  // 减小内边距
        let bottomBarHeight: CGFloat = 20  // 精简底部栏

        // 根据窗口数量动态计算合适的列数
        let columnCount: Int
        if ConfigManager.shared.config.appearance.switcherColumns > 0 {
            columnCount = ConfigManager.shared.config.appearance.switcherColumns
        } else {
            let maxPanelWidth: CGFloat = 1400
            let maxPossibleColumns = Int((maxPanelWidth - panelPadding * 2 + desiredSpacing) / (itemWidth + desiredSpacing))
            columnCount = max(1, min(8, min(windowCount, maxPossibleColumns)))
        }

        let rowCount = max(1, (windowCount + columnCount - 1) / columnCount)

        // 获取屏幕尺寸
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)

        // 计算内容所需尺寸（无额外空白）
        let itemSpacing: CGFloat = 4  // 紧凑间距
        let contentWidth = CGFloat(columnCount) * (itemWidth + desiredSpacing) - desiredSpacing + panelPadding * 2
        let contentHeight = CGFloat(rowCount) * (itemHeight + itemSpacing) + panelPadding * 2 + bottomBarHeight

        // 最小面板尺寸
        let minWidth: CGFloat
        let minHeight: CGFloat

        switch windowCount {
        case 1:
            minWidth = itemWidth + panelPadding * 2 + 8
            minHeight = itemHeight + panelPadding * 2 + bottomBarHeight
        case 2:
            minWidth = itemWidth * 2 + desiredSpacing + panelPadding * 2 + 8
            minHeight = itemHeight + panelPadding * 2 + bottomBarHeight
        case 3, 4:
            let cols = min(windowCount, columnCount)
            minWidth = itemWidth * CGFloat(cols) + desiredSpacing * CGFloat(cols - 1) + panelPadding * 2 + 8
            minHeight = itemHeight + panelPadding * 2 + bottomBarHeight
        default:
            minWidth = 350
            minHeight = 200
        }

        let maxWidth = screenSize.width * 0.9
        let maxHeight = screenSize.height * 0.8

        // 最终面板尺寸 - 完全贴合内容
        let panelWidth = min(max(contentWidth, minWidth), maxWidth)
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

        // 先显示背景预览窗口（在切换器面板之前）
        Logger.info("==> Initial selectedWindow: \(vm.selectedWindow?.appName ?? "nil"), selectedIndex: \(vm.selectedIndex)")
        showBackgroundPreview(for: vm.selectedWindow, screenFrame: NSScreen.main?.frame ?? .zero, panelFrame: panel.frame)

        // 再显示切换器面板（会覆盖背景预览）
        PanelAnimator.show(panel)
        switchPanelWindow = panel

        // 设置 ESC 键全局监听器
        setupEscKeyMonitor()

        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("==> showSwitchPanel TOTAL: \(totalTime)ms, \(sortedWindows.count) windows")

        // 批量预加载所有窗口缩略图
        preloadAllPreviews(windows: sortedWindows, viewModel: vm)

        // 监听选中窗口变化，更新背景预览
        setupSelectedWindowObserver(for: vm)
    }

    // MARK: - 背景预览窗口
    private var backgroundPreviewWindow: NSPanel?

    private func showBackgroundPreview(for window: WindowModel?, screenFrame: CGRect, panelFrame: CGRect) {
        // 检查是否启用背景预览
        guard ConfigManager.shared.config.behavior.showBackgroundPreview else { return }

        guard let window = window else { return }

        // 背景预览窗口覆盖整个屏幕
        let previewFrame = screenFrame

        let previewPanel = NSPanel(
            contentRect: previewFrame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        previewPanel.isFloatingPanel = true
        previewPanel.level = .floating  // 浮动层级
        previewPanel.backgroundColor = .clear
        previewPanel.isOpaque = false
        previewPanel.hasShadow = false
        previewPanel.titleVisibility = .hidden
        previewPanel.titlebarAppearsTransparent = true
        previewPanel.ignoresMouseEvents = true
        previewPanel.hidesOnDeactivate = false
        previewPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // 创建预览视图
        let previewView = BackgroundPreviewContainer(selectedWindow: window)
        let hostingView = NSHostingView(rootView: previewView)
        hostingView.frame = NSRect(origin: .zero, size: previewFrame.size)
        previewPanel.contentView = hostingView

        // 显示预览窗口
        previewPanel.orderFront(nil)
        backgroundPreviewWindow = previewPanel

        Logger.info("==> Background preview shown for: \(window.appName), frame: \(window.frame)")
    }

    private func updateBackgroundPreview(for window: WindowModel?) {
        guard ConfigManager.shared.config.behavior.showBackgroundPreview else { return }
        guard let window = window else { return }

        Logger.info("==> Updating background preview for: \(window.appName), windowID: \(window.id)")

        // 更新预览内容 - 重新创建整个视图确保更新
        if let panel = backgroundPreviewWindow {
            let previewFrame = panel.frame
            let newView = BackgroundPreviewContainer(selectedWindow: window)
            let newHostingView = NSHostingView(rootView: newView)
            newHostingView.frame = NSRect(origin: .zero, size: previewFrame.size)
            panel.contentView = newHostingView
        }
    }

    private func hideBackgroundPreview() {
        backgroundPreviewWindow?.orderOut(nil)
        backgroundPreviewWindow = nil
    }

    @MainActor
    private func setupSelectedWindowObserver(for vm: SwitchPanelViewModel) {
        // 取消之前的监听
        selectedWindowCancellable?.cancel()

        // 监听选中索引变化
        selectedWindowCancellable = vm.$selectedIndex
            .sink { [weak self] newIndex in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let selectedWindow = vm.selectedWindow {
                        self.updateBackgroundPreview(for: selectedWindow)
                    }
                }
            }
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

        // 移除选中窗口监听
        selectedWindowCancellable?.cancel()
        selectedWindowCancellable = nil

        // 隐藏背景预览窗口
        hideBackgroundPreview()

        guard let panel = switchPanelWindow else { return }
        PanelAnimator.hide(panel) { [weak self] in
            self?.switchPanelWindow = nil
            self?.isPanelVisible = false
            Logger.info("Switch panel hidden")
        }
    }
}
