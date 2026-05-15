import AppKit
import SwiftUI
import Carbon
import Combine

// Carbon 修饰键常量（来自 Carbon HIToolbox/Events.h）
// 正确的值：cmdKey = 256, shiftKey = 512, optionKey = 2048, controlKey = 4096
private let carbonCmdKey: UInt32 = 256          // ⌘ Command (cmdKey = 1 << 8)
private let carbonShiftKey: UInt32 = 512        // ⇧ Shift (shiftKey = 1 << 9)
private let carbonOptionKey: UInt32 = 2048      // ⌥ Option (optionKey = 1 << 11)
private let carbonControlKey: UInt32 = 4096     // ⌃ Control (controlKey = 1 << 12)

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var switchPanelWindow: NSWindow?
    private var settingsWindow: NSWindow?  // 设置窗口引用
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?   // 鼠标点击全局监听器
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
    private var largePreviewCancellable: AnyCancellable?
    private var selectedWindowCancellable: AnyCancellable?  // 监听选中窗口变化

    // 标记是否已完成延迟初始化
    private var deferredInitCompleted = false
    private var dockPreviewConfigCancellable: AnyCancellable?

    // 监听切换器快捷键的修饰键状态
    private var wasSwitchModifierPressed = false  // 跟踪切换器快捷键修饰键状态
    private var panelShowTime: CFAbsoluteTime = 0  // 面板显示时间，用于忽略假释放事件
    private let ignoreReleaseDelay: CFAbsoluteTime = 0.15  // 忽略面板显示后 150ms 内的释放事件

    // 快速切换：按住组合键不放时延迟显示面板
    private var panelShowDelayTimer: Timer?
    private var pendingSwitchWindow: WindowModel?  // 待切换的窗口（用于快速切换）
    private var pendingSwitchReversed: Bool = false  // 是否反向切换

    // 版本更新提示窗口
    private var updateNotificationController: UpdateNotificationWindowController?
    // 安装进度窗口
    private var installProgressController: InstallProgressWindowController?

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
        // 清理过期的窗口活动记录
        WindowActivityStore.shared.cleanupOldRecords()

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

        // 启动自动更新检查（如果已启用）
        setupAutoUpdateCheck()
        Logger.info("9. Auto update check setup complete")

        Logger.info("=== Deferred initialization completed ===")
    }

    /// 设置自动更新检查
    private func setupAutoUpdateCheck() {
        // 监听自动检查更新通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdateAvailable),
            name: .updateAvailable,
            object: nil
        )

        // 监听安装进度窗口显示通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInstallProgress),
            name: .showInstallProgress,
            object: nil
        )

        if ConfigManager.shared.config.update.autoCheckEnabled {
            UpdateService.shared.startAutoCheck()
        } else {
            // 只有自动检查关闭时才手动检查一次
            checkForUpdateOnLaunch()
        }
    }

    /// 处理自动检查更新发现新版本的通知
    @objc private func handleUpdateAvailable() {
        Logger.operation("自动更新检查", detail: "发现新版本，显示更新提示")
        showUpdateNotification()
    }

    /// 处理显示安装进度窗口的通知
    @objc private func handleShowInstallProgress() {
        Logger.operation("静默安装", detail: "显示安装进度窗口")
        showInstallProgress()
    }

    /// 首次启动时检查版本更新
    private func checkForUpdateOnLaunch() {
        Logger.operation("启动更新检查", detail: "开始执行")
        Task {
            await UpdateService.shared.checkForUpdate()

            // 如果有新版本，显示更新提示
            Logger.operation("启动更新检查", detail: "检查完成, updateAvailable: \(UpdateService.shared.updateAvailable)")
            if UpdateService.shared.updateAvailable {
                await MainActor.run {
                    Logger.operation("启动更新检查", detail: "准备显示更新提示窗口")
                    showUpdateNotification()
                }
            }
        }
    }

    /// 显示版本更新提示窗口
    private func showUpdateNotification() {
        Logger.operation("更新提示", detail: "创建窗口控制器")
        updateNotificationController = UpdateNotificationWindowController { [weak self] in
            self?.updateNotificationController?.close()
            self?.updateNotificationController = nil
        }
        updateNotificationController?.show()
        Logger.operation("更新提示", detail: "窗口已显示")
    }

    /// 显示安装进度窗口
    private func showInstallProgress() {
        Logger.operation("安装进度", detail: "创建窗口控制器")
        installProgressController = InstallProgressWindowController { [weak self] in
            self?.installProgressController?.close()
            self?.installProgressController = nil
        }
        installProgressController?.show()

        // 开始静默安装
        if let fileURL = UpdateDownloadManager.shared.localFileURL {
            SilentInstaller.shared.install(from: fileURL) { result in
                switch result {
                case .success:
                    Logger.operation("静默安装", detail: "安装成功", result: "成功")
                case .failure(let error):
                    Logger.operation("静默安装", detail: "安装失败: \(error.localizedDescription ?? "未知错误")", result: "失败")
                }
            }
        }
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
                        self?.hideLargePreview()
                    }
                }
            }

        // 监听大预览项目变化
        largePreviewCancellable = DockPreviewManager.shared.$largePreviewItem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                if let item = item {
                    self?.showLargePreview(for: item)
                } else {
                    self?.hideLargePreview()
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
        largePreviewCancellable?.cancel()
        largePreviewCancellable = nil

        // 隐藏预览窗口（在主线程）
        Task { @MainActor in
            self.hideDockPreviewPanel()
        }
    }

    // MARK: - 大预览窗口
    private var largePreviewWindow: NSPanel?

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

    // MARK: - 大预览窗口
    private func showLargePreview(for item: DockPreviewItem) {
        // 隐藏已有的大预览窗口
        hideLargePreview()

        let manager = DockPreviewManager.shared

        // 创建大预览视图
        let largePreviewView = LargeDockPreviewView(
            item: item,
            previewWidth: manager.largePreviewWidth,
            previewHeight: manager.largePreviewHeight,
            previewGenerator: manager.previewGenerator
        )

        // 获取屏幕尺寸，创建全屏面板
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        // 创建全屏面板
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating  // 低于 popUpMenu，确保预览面板在上层
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: largePreviewView)
        hostingView.frame = NSRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
        panel.contentView = hostingView
        // 设置面板位置在屏幕左下角（macOS 坐标系原点）
        panel.setFrameOrigin(NSPoint(x: screenFrame.origin.x, y: screenFrame.origin.y))

        // 显示（带动画）
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        largePreviewWindow = panel
    }

    private func hideLargePreview() {
        guard let window = largePreviewWindow else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }

        largePreviewWindow = nil
    }

    // 监听切换器快捷键的修饰键释放 - 根据配置动态检测
    private func setupOptionKeyMonitor() {
        Logger.info("==> setupOptionKeyMonitor called")

        // 使用全局监听器捕获修饰键变化事件（即使面板显示时也能捕获）
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }

            // 获取当前快捷键配置中的修饰键
            let switchModifiers = self.configManager.config.hotKeys.switchModifiers

            // 获取原始的 modifierFlags 原始值（用于调试）
            let rawFlags = event.modifierFlags.rawValue

            // 获取实际的 modifierFlags（排除设备无关标志）
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdPressed = flags.contains(.command)
            let isOptionPressed = flags.contains(.option)
            let isShiftPressed = flags.contains(.shift)
            let isControlPressed = flags.contains(.control)

            // 检查是否有待切换的窗口（快速切换模式）
            if self.pendingSwitchWindow != nil {
                // 检查配置中的修饰键是否全部释放
                var allModifiersReleased = true
                if switchModifiers & carbonCmdKey != 0 && flags.contains(.command) { allModifiersReleased = false }
                if switchModifiers & carbonOptionKey != 0 && flags.contains(.option) { allModifiersReleased = false }
                if switchModifiers & carbonControlKey != 0 && flags.contains(.control) { allModifiersReleased = false }

                if allModifiersReleased {
                    // 快速切换：直接激活目标窗口
                    Logger.operation("快速切换", detail: "修饰键释放，执行快速切换")
                    self.performQuickSwitch()
                    return
                }
            }

            // 只有在面板可见时才处理后续逻辑
            guard self.isPanelVisible else {
                Logger.debug("Global flagsChanged ignored: panel not visible")
                return
            }

            // 详细日志：记录所有修饰键状态
            Logger.flagsChanged("Global: Cmd=\(isCmdPressed), Opt=\(isOptionPressed), Shift=\(isShiftPressed), Ctrl=\(isControlPressed), raw=0x\(String(rawFlags, radix: 16)), config=0x\(String(switchModifiers, radix: 16))")

            // 直接检查配置中的修饰键是否释放
            var allModifiersReleased = true

            // 检查 Cmd
            if switchModifiers & carbonCmdKey != 0 {
                if flags.contains(.command) {
                    allModifiersReleased = false
                }
            }
            // 检查 Option
            if switchModifiers & carbonOptionKey != 0 {
                if flags.contains(.option) {
                    allModifiersReleased = false
                }
            }
            // 检查 Control
            if switchModifiers & carbonControlKey != 0 {
                if flags.contains(.control) {
                    allModifiersReleased = false
                }
            }

            // 检测切换器修饰键释放：当所有配置的修饰键都释放时关闭切换器
            if self.wasSwitchModifierPressed && allModifiersReleased {
                // 检查是否在延迟时间内（忽略面板显示后的假释放事件）
                let timeSinceShow = CFAbsoluteTimeGetCurrent() - self.panelShowTime
                if timeSinceShow < self.ignoreReleaseDelay {
                    let delay = self.ignoreReleaseDelay - timeSinceShow
                    Logger.flagsChanged("Global: Ignoring early release (timeSinceShow=\(String(format: "%.3f", timeSinceShow))s), scheduling check after \(String(format: "%.3f", delay))s")
                    // 安排延迟后的检查
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.checkModifierStateAfterDelay()
                    }
                    return
                }

                Logger.modifierState("释放", detail: "allModifiersReleased=true")
                Logger.info("Global: ALL modifiers RELEASED! Calling activateSelectedAndHide()")
                Task { @MainActor in
                    self.activateSelectedAndHide()
                }
            } else if !allModifiersReleased {
                // 至少有一个修饰键仍然按下，更新状态，保持切换器打开
                self.wasSwitchModifierPressed = true
            }
        }

        // 同时使用本地监听器作为备份
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }

            // 只有在面板可见时才处理
            guard self.isPanelVisible else { return event }

            // 获取当前快捷键配置中的修饰键
            let switchModifiers = self.configManager.config.hotKeys.switchModifiers

            // 获取原始的 modifierFlags 原始值
            let rawFlags = event.modifierFlags.rawValue
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdPressed = flags.contains(.command)
            let isOptionPressed = flags.contains(.option)
            let isShiftPressed = flags.contains(.shift)
            let isControlPressed = flags.contains(.control)

            // 详细日志：记录所有修饰键状态
            Logger.flagsChanged("Local: Cmd=\(isCmdPressed), Opt=\(isOptionPressed), Shift=\(isShiftPressed), Ctrl=\(isControlPressed), raw=0x\(String(rawFlags, radix: 16)), config=0x\(String(switchModifiers, radix: 16))")

            // 直接检查配置中的修饰键是否释放
            var allModifiersReleased = true

            // 检查 Cmd
            if switchModifiers & carbonCmdKey != 0 {
                if flags.contains(.command) {
                    allModifiersReleased = false
                }
            }
            // 检查 Option
            if switchModifiers & carbonOptionKey != 0 {
                if flags.contains(.option) {
                    allModifiersReleased = false
                }
            }
            // 检查 Control
            if switchModifiers & carbonControlKey != 0 {
                if flags.contains(.control) {
                    allModifiersReleased = false
                }
            }

            // 检测切换器修饰键释放：当所有配置的修饰键都释放时关闭切换器
            if self.wasSwitchModifierPressed && allModifiersReleased {
                // 检查是否在延迟时间内（忽略面板显示后的假释放事件）
                let timeSinceShow = CFAbsoluteTimeGetCurrent() - self.panelShowTime
                if timeSinceShow < self.ignoreReleaseDelay {
                    let delay = self.ignoreReleaseDelay - timeSinceShow
                    Logger.flagsChanged("Local: Ignoring early release (timeSinceShow=\(String(format: "%.3f", timeSinceShow))s), scheduling check after \(String(format: "%.3f", delay))s")
                    // 安排延迟后的检查
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.checkModifierStateAfterDelay()
                    }
                    return event
                }

                Logger.modifierState("释放", detail: "allModifiersReleased=true")
                Logger.info("Local: ALL modifiers RELEASED! Calling activateSelectedAndHide()")
                Task { @MainActor in
                    self.activateSelectedAndHide()
                }
            } else if !allModifiersReleased {
                // 至少有一个修饰键仍然按下，更新状态，保持切换器打开
                self.wasSwitchModifierPressed = true
            }

            return event
        }

        // 3. 添加全局鼠标点击监听 - 点击面板外区域关闭面板
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation

            // 检查点击是否在切换面板窗口内
            if self.isPanelVisible, let panelWindow = self.switchPanelWindow {
                let panelFrame = panelWindow.frame

                // 如果点击在面板窗口内，不处理
                if panelFrame.contains(mouseLocation) {
                    Logger.debug("Mouse click inside panel, ignoring")
                    return
                }

                // 点击在面板外，关闭面板（但不激活任何窗口）
                Logger.info("Mouse click outside panel, hiding panel without activation")
                Task { @MainActor in
                    self.hideSwitchPanel()
                }
            }

            // 检查点击是否在程序坞预览窗口外
            if let dockPreview = self.dockPreviewWindow {
                let dockFrame = dockPreview.frame

                // 如果点击在预览窗口内，不处理
                if dockFrame.contains(mouseLocation) {
                    return
                }

                // 点击在预览窗口外，隐藏预览
                Task { @MainActor in
                    DockPreviewManager.shared.hidePreviewPanel()
                }
            }
        }

        Logger.info("==> setupOptionKeyMonitor completed, globalKeyMonitor=\(globalKeyMonitor != nil), localKeyMonitor=\(localKeyMonitor != nil), globalMouseMonitor=\(globalMouseMonitor != nil)")
    }

    /// 延迟后检查修饰键状态（用于处理面板显示后的假释放事件）
    private func checkModifierStateAfterDelay() {
        // 确保面板仍然可见
        guard isPanelVisible else {
            Logger.flagsChanged("DelayedCheck: Panel no longer visible, skipping")
            return
        }

        // 获取当前修饰键状态
        let currentFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let switchModifiers = configManager.config.hotKeys.switchModifiers

        Logger.flagsChanged("DelayedCheck: Checking modifier state after delay")

        // 检查配置的修饰键是否仍然按下
        var allModifiersReleased = true

        if switchModifiers & carbonCmdKey != 0 {
            if currentFlags.contains(.command) {
                allModifiersReleased = false
                Logger.flagsChanged("DelayedCheck: Cmd still pressed")
            }
        }
        if switchModifiers & carbonOptionKey != 0 {
            if currentFlags.contains(.option) {
                allModifiersReleased = false
                Logger.flagsChanged("DelayedCheck: Opt still pressed")
            }
        }
        if switchModifiers & carbonControlKey != 0 {
            if currentFlags.contains(.control) {
                allModifiersReleased = false
                Logger.flagsChanged("DelayedCheck: Ctrl still pressed")
            }
        }

        if allModifiersReleased && wasSwitchModifierPressed {
            Logger.info("DelayedCheck: All modifiers released, activating window")
            Task { @MainActor in
                self.activateSelectedAndHide()
            }
        } else {
            Logger.flagsChanged("DelayedCheck: Modifiers still pressed or wasSwitchModifierPressed=false, keeping panel open")
        }
    }

    // 将 Carbon 修饰键转换为 NSEvent.ModifierFlags（用于日志显示）
    private func carbonToCocoaModifiers(_ carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & carbonCmdKey != 0 { parts.append("⌘") }
        if carbonModifiers & carbonOptionKey != 0 { parts.append("⌥") }
        if carbonModifiers & carbonShiftKey != 0 { parts.append("⇧") }
        if carbonModifiers & carbonControlKey != 0 { parts.append("⌃") }
        return parts.isEmpty ? "无" : parts.joined()
    }

    // 检查配置的修饰键是否按下
    private func checkModifiersPressed(modifierFlags: NSEvent.ModifierFlags, carbonModifiers: UInt32) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var isPressed = true

        // 检查每个配置的修饰键
        if carbonModifiers & carbonCmdKey != 0 {
            isPressed = isPressed && flags.contains(.command)
        }
        if carbonModifiers & carbonOptionKey != 0 {
            isPressed = isPressed && flags.contains(.option)
        }
        if carbonModifiers & carbonShiftKey != 0 {
            isPressed = isPressed && flags.contains(.shift)
        }
        if carbonModifiers & carbonControlKey != 0 {
            isPressed = isPressed && flags.contains(.control)
        }

        return isPressed
    }

    /// 激活选中的窗口并隐藏面板（优化时序 - 并行执行）
    @MainActor
    private func activateSelectedAndHide() {
        Logger.info("=== activateSelectedAndHide called ===")

        // 先立即隐藏面板（无动画，用户感知更快）
        hideSwitchPanelImmediately()

        guard let vm = switchPanelViewModel else {
            Logger.error("switchPanelViewModel is nil! Cannot activate window.")
            return
        }

        // 1. 优先使用 selectedWindowID 激活
        if let windowID = vm.selectedWindowID {
            Logger.modifierState("释放")
            if let window = vm.filteredWindows.first(where: { $0.id == windowID }) {
                Logger.windowActivate("\(window.appName) - \(window.windowTitle)", result: "通过 selectedWindowID")
            }
            vm.activateWindowByID(windowID)
            return
        }

        // 2. 降级：使用 selectedWindow
        guard let selectedWindow = vm.selectedWindow else {
            Logger.warning("No selected window to activate (selectedWindow is nil)")
            return
        }

        Logger.modifierState("释放")
        Logger.windowActivate("\(selectedWindow.appName) - \(selectedWindow.windowTitle)", result: "通过 selectedWindow")
        windowManager.activateWindow(selectedWindow)
    }

    /// 立即隐藏切换面板（无动画，用于释放修饰键时）
    private func hideSwitchPanelImmediately() {
        Logger.panelState("隐藏", detail: "immediately, wasSwitchModifierPressed=\(wasSwitchModifierPressed)")

        // 立即标记面板不可见
        isPanelVisible = false
        wasSwitchModifierPressed = false

        // 恢复焦点轮询
        windowManager.resumeFocusPolling()

        // 停止刷新定时器
        stopWindowRefreshTimer()

        // 移除 ESC 键监听器
        removeEscKeyMonitor()

        // 移除选中窗口监听
        selectedWindowCancellable?.cancel()
        selectedWindowCancellable = nil

        // 隐藏背景预览窗口
        hideBackgroundPreview()

        // 立即隐藏面板（无动画）
        guard let panel = switchPanelWindow else { return }
        panel.orderOut(nil)
        switchPanelWindow = nil
        Logger.info("Switch panel hidden immediately")
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
            let now = Date()
            guard now.timeIntervalSince(self.lastHotKeyTime) > 0.003 else { return }  // 3ms 节流
            self.lastHotKeyTime = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isPanelVisible {
                    // 面板已显示，选中下一个窗口
                    NotificationCenter.default.post(name: .switchHotKeyPressed, object: nil)
                } else {
                    // 延迟显示面板，快速按放时直接切换窗口
                    self.startPanelShowDelay(reversed: false)
                }
            }
        }

        // 反向切换：Shift + 切换器快捷键
        hotKeyManager.register(
            HotKey(keyCode: switchKeyCode, modifiers: switchModifiers | UInt32(shiftKey), identifier: "reverseSwitch")
        ) { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastHotKeyTime) > 0.003 else { return }  // 3ms 节流
            self.lastHotKeyTime = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isPanelVisible {
                    // 面板已显示，选中上一个窗口
                    NotificationCenter.default.post(name: .reverseSwitchHotKeyPressed, object: nil)
                } else {
                    // 延迟显示面板，快速按放时直接切换窗口
                    self.startPanelShowDelay(reversed: true)
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
            openSettings()
        }
    }

    @objc private func showSwitcherFromMenu() {
        Task { @MainActor in self.showSwitchPanel() }
    }

    private func requestPermissions() {
        // 使用权限管理器检查状态
        let permissionManager = PermissionManager.shared

        // 初始检查权限状态
        permissionManager.checkAllPermissions()

        Logger.info("Permission check - Accessibility: \(permissionManager.accessibilityStatus.rawValue), Screen Recording: \(permissionManager.screenRecordingStatus.rawValue)")

        // 检查屏幕录制权限 - 只有在没有权限且未请求过时才提示
        let screenPermissionKey = "hasRequestedScreenPermission"
        let hasRequestedScreen = UserDefaults.standard.bool(forKey: screenPermissionKey)

        if !permissionManager.screenRecordingStatus.isAuthorized && !hasRequestedScreen {
            showDetailedPermissionAlert(
                for: "屏幕录制",
                description: permissionManager.getScreenRecordingPermissionDescription(),
                permissionKey: screenPermissionKey,
                openSettingsAction: { permissionManager.openScreenRecordingSettings() }
            )
        } else if permissionManager.screenRecordingStatus.isAuthorized {
            UserDefaults.standard.set(false, forKey: screenPermissionKey)
            Logger.info("Screen recording permission granted")
        }

        // 辅助功能权限检查 - 只有在没有权限且未请求过时才提示
        let accessibilityPermissionKey = "hasRequestedAccessibilityPermission"
        let hasRequestedAccessibility = UserDefaults.standard.bool(forKey: accessibilityPermissionKey)

        if !permissionManager.accessibilityStatus.isAuthorized && !hasRequestedAccessibility {
            showDetailedPermissionAlert(
                for: "辅助功能",
                description: permissionManager.getAccessibilityPermissionDescription(),
                permissionKey: accessibilityPermissionKey,
                openSettingsAction: { permissionManager.openAccessibilitySettings() }
            )
        } else if permissionManager.accessibilityStatus.isAuthorized {
            UserDefaults.standard.set(false, forKey: accessibilityPermissionKey)
            Logger.info("Accessibility permission granted")
        }

        // 启动权限状态监测
        permissionManager.startMonitoring()

        // 监听权限变更通知
        setupPermissionChangeListener()

        // 更新菜单栏图标状态
        updateMenuBarIcon(hasPermissions: permissionManager.hasAllRequiredPermissions)
    }

    private func setupPermissionChangeListener() {
        NotificationCenter.default.addObserver(
            forName: .permissionStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let pm = PermissionManager.shared
            let hasPermissions = pm.hasAllRequiredPermissions
            self?.updateMenuBarIcon(hasPermissions: hasPermissions)

            if hasPermissions {
                Logger.info("All permissions granted - UI updated")
            }
        }
    }

    /// 显示详细的权限提示对话框
    private func showDetailedPermissionAlert(
        for permission: String,
        description: (title: String, description: String),
        permissionKey: String,
        openSettingsAction: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "需要\(permission)权限"
        alert.informativeText = description.description
        alert.alertStyle = .warning

        // 添加详细说明
        let infoText = """
        请在系统设置中开启权限，以启用以下功能：
        • 窗口预览和切换
        • 快捷键响应
        • 程序坞预览

        点击"打开系统设置"前往授权，或点击"稍后"稍后再设置。
        """

        alert.informativeText = description.description + "\n\n" + infoText

        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "不再提示")
        alert.addButton(withTitle: "稍后")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // 用户点击"打开系统设置"
            UserDefaults.standard.set(true, forKey: permissionKey)
            openSettingsAction()
        case .alertSecondButtonReturn:
            // 用户点击"不再提示"
            UserDefaults.standard.set(true, forKey: permissionKey)
            Logger.info("User chose not to be prompted for \(permission) permission again")
        default:
            // 用户点击"稍后"，不改变状态
            break
        }
    }

    private func updateMenuBarIcon(hasPermissions: Bool) {
        if let image = loadStatusBarIcon() {
            // 权限缺失时降低透明度
            statusItem?.button?.alphaValue = hasPermissions ? 1.0 : 0.5
            statusItem?.button?.image = image
        }
    }

    @objc func openSettings() {
        // 如果设置窗口已存在，直接激活
        if let existingWindow = settingsWindow {
            NSApp.setActivationPolicy(.regular)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 计算响应式窗口尺寸
        let windowSize = ResponsiveSize.settingsWindowSize()
        let minSize = ResponsiveSize.minWindowSize

        // 创建设置窗口
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "WindowsSwitcher 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(windowSize)
        window.minSize = minSize
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        settingsWindow = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // 检查是否是设置窗口关闭
        if window === settingsWindow {
            NSApp.setActivationPolicy(.accessory)
            Logger.info("设置窗口已关闭，切换回 accessory 模式")
        }
    }

    // MARK: - 快速切换（延迟显示面板）
    /// 启动延迟显示面板的定时器
    /// 如果在延迟期间修饰键释放，直接切换窗口，不显示面板
    private func startPanelShowDelay(reversed: Bool) {
        Logger.operation("快速切换", detail: "startPanelShowDelay 被调用，reversed=\(reversed)")

        // 检查修饰键是否仍在按下
        let currentFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let rawFlags = NSEvent.modifierFlags.rawValue
        let switchModifiers = configManager.config.hotKeys.switchModifiers

        let isCmdPressed = currentFlags.contains(.command)
        let isOptionPressed = currentFlags.contains(.option)
        let isControlPressed = currentFlags.contains(.control)

        var modifiersPressed = false
        if switchModifiers & carbonCmdKey != 0 && isCmdPressed { modifiersPressed = true }
        if switchModifiers & carbonOptionKey != 0 && isOptionPressed { modifiersPressed = true }
        if switchModifiers & carbonControlKey != 0 && isControlPressed { modifiersPressed = true }

        Logger.operation("快速切换", detail: "修饰键状态: cmd=\(isCmdPressed), opt=\(isOptionPressed), ctrl=\(isControlPressed), config=0x\(String(switchModifiers, radix: 16)), raw=0x\(String(rawFlags, radix: 16))")

        // 如果修饰键已经释放，直接切换窗口
        if !modifiersPressed {
            Logger.operation("快速切换", detail: "修饰键已释放，直接切换")
            // 获取窗口列表
            let windows = windowManager.getAllWindows()
            // 切换到下一个窗口（索引1），与正常切换逻辑一致
            if windows.count >= 2 {
                let targetIndex = reversed ? windows.count - 1 : 1
                DispatchQueue.main.async { [weak self] in
                    self?.windowManager.activateWindow(windows[targetIndex])
                }
            }
            return
        }

        // 取消之前的定时器
        cancelPanelShowDelay()

        // 获取窗口列表，找到目标窗口
        let windows = windowManager.getAllWindows()
        Logger.operation("快速切换", detail: "获取到 \(windows.count) 个窗口")

        guard windows.count >= 2 else {
            Logger.operation("快速切换", detail: "窗口数量不足，返回")
            return
        }

        // 快速切换：切换到下一个窗口（索引1），因为索引0是当前窗口
        // 反向切换：切换到最后一个窗口
        let targetIndex = reversed ? windows.count - 1 : 1
        pendingSwitchWindow = windows[targetIndex]
        pendingSwitchReversed = reversed

        Logger.operation("快速切换", detail: "启动延迟，targetIndex=\(targetIndex), window=\(windows[targetIndex].windowTitle)")

        // 从配置读取延迟时间，如果<=0则使用默认值
        let panelDisplayDelay = configManager.config.behavior.panelDisplayDelay
        let effectiveDelay = panelDisplayDelay > 0 ? panelDisplayDelay : 0.15  // 默认150ms
        Logger.operation("快速切换", detail: "panelDisplayDelay=\(panelDisplayDelay), effectiveDelay=\(effectiveDelay)")

        Logger.operation("快速切换", detail: "启动定时器，延迟\(effectiveDelay)秒")

        // 启动延迟定时器
        panelShowDelayTimer = Timer.scheduledTimer(withTimeInterval: effectiveDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // 延迟到期，显示面板
            self.pendingSwitchWindow = nil
            Task { @MainActor in
                self.showSwitchPanel(reversed: reversed)
            }
        }
    }

    /// 取消延迟显示面板
    private func cancelPanelShowDelay() {
        panelShowDelayTimer?.invalidate()
        panelShowDelayTimer = nil
        pendingSwitchWindow = nil
    }

    /// 执行快速切换（直接激活窗口，不显示面板）
    private func performQuickSwitch() {
        guard let window = pendingSwitchWindow else { return }
        Logger.operation("快速切换", detail: "直接激活窗口: \(window.windowTitle)")

        // 清理状态（先清理，避免重复触发）
        pendingSwitchWindow = nil
        cancelPanelShowDelay()

        // 在主线程激活窗口
        DispatchQueue.main.async { [weak self] in
            self?.windowManager.activateWindow(window)
        }
    }

    // MARK: - 切换面板
    @MainActor
    func showSwitchPanel(reversed: Bool = false, appSwitchMode: Bool = false) {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 在显示面板前先记录当前前台应用（因为显示面板后 frontmostApplication 会变成我们的面板）
        let previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        let previousPID = previousFrontmostApp?.processIdentifier
        let previousBundleID = previousFrontmostApp?.bundleIdentifier

        // 操作日志：面板显示
        Logger.panelState("显示", detail: "reversed=\(reversed), appSwitchMode=\(appSwitchMode), 前台应用=\(previousBundleID ?? "unknown")")

        Logger.info("==> showSwitchPanel START (reversed=\(reversed), appSwitchMode=\(appSwitchMode))")
        Logger.info("==> Previous frontmost app: \(previousBundleID ?? "unknown"), PID: \(previousPID ?? -1)")

        guard !isPanelVisible else { return }
        isPanelVisible = true

        // 暂停焦点轮询，避免窗口列表在切换过程中变化
        windowManager.pauseFocusPolling()

        // 初始化切换器修饰键状态为 true（假设用户正在按切换快捷键）
        // 然后在 flagsChanged 监听器中检测修饰键释放
        wasSwitchModifierPressed = true
        panelShowTime = CFAbsoluteTimeGetCurrent()  // 记录面板显示时间
        let switchModifiers = configManager.config.hotKeys.switchModifiers
        Logger.info("==> Panel shown, initialized wasSwitchModifierPressed = true, modifiers=\(carbonToCocoaModifiers(switchModifiers))")

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
                    ownerPID: windows[maxIndex].ownerPID,
                    isStandardWindow: windows[maxIndex].isStandardWindow
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
        if reversed && sortedWindows.count > 1 {
            // 反向切换：选择第二个窗口（上一个最近使用的窗口）
            vm.selectedIndex = 1
            Logger.info("==> reversed mode: selecting index 1 (previous window)")
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
        panel.ignoresMouseEvents = false  // 确保面板接收鼠标事件
        panel.acceptsMouseMovedEvents = true  // 确保面板接收鼠标移动事件（悬停）
        panel.hidesOnDeactivate = false  // 确保面板不会因为失去焦点而隐藏

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

        // 先加载第一个窗口的预览图，减少空白闪烁
        preloadFirstPreview(for: sortedWindows, viewModel: vm)

        // 显示背景预览窗口（在切换器面板之前）
        Logger.info("==> Initial selectedWindow: \(vm.selectedWindow?.appName ?? "nil"), selectedIndex: \(vm.selectedIndex)")
        showBackgroundPreview(for: vm.selectedWindow, screenFrame: NSScreen.main?.frame ?? .zero, panelFrame: panel.frame)

        // 显示切换器面板
        PanelAnimator.show(panel)
        switchPanelWindow = panel

        // 设置 ESC 键全局监听器
        setupEscKeyMonitor()

        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("==> showSwitchPanel TOTAL: \(totalTime)ms, \(sortedWindows.count) windows")

        // 继续异步加载其余窗口缩略图
        preloadRemainingPreviews(windows: sortedWindows, viewModel: vm)

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

    // 先加载第一个窗口的预览图，减少空白闪烁
    private func preloadFirstPreview(for windows: [WindowModel], viewModel: SwitchPanelViewModel) {
        guard let firstWindow = windows.first else { return }

        let sizeConfig = ConfigManager.shared.config.appearance.previewSize.dimensions
        let previewSize = CGSize(width: sizeConfig.width, height: sizeConfig.height)

        // 同步加载第一个预览图
        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            if let image = await previewGenerator.generateRealtimePreview(for: firstWindow, size: previewSize) {
                await MainActor.run {
                    viewModel.previewImages[firstWindow.id] = image
                    Logger.info("==> First preview loaded in \((CFAbsoluteTimeGetCurrent() - startTime)*1000)ms")
                }
            }
        }
    }

    // 异步加载其余窗口缩略图
    private func preloadRemainingPreviews(windows: [WindowModel], viewModel: SwitchPanelViewModel) {
        guard windows.count > 1 else { return }

        let sizeConfig = ConfigManager.shared.config.appearance.previewSize.dimensions
        let previewSize = CGSize(width: sizeConfig.width, height: sizeConfig.height)

        // 异步加载剩余窗口的预览图
        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            let remainingWindows = Array(windows.dropFirst())
            let previewImages = await previewGenerator.generatePreviews(for: remainingWindows, size: previewSize)

            await MainActor.run {
                for (windowID, image) in previewImages {
                    viewModel.previewImages[windowID] = image
                }
                Logger.info("==> Remaining \(previewImages.count) previews loaded in \((CFAbsoluteTimeGetCurrent() - startTime)*1000)ms")
            }
        }
    }

    // 设置 ESC 键全局监听器
    private func setupEscKeyMonitor() {
        // 先移除旧的监听器
        removeEscKeyMonitor()

        Logger.operation("ESC监听器", detail: "开始设置")

        // 使用全局监听器监听键盘事件
        globalEscKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            Logger.operation("全局键盘", detail: "keyCode=\(event.keyCode), isRepeat=\(event.isARepeat), isPanelVisible=\(self.isPanelVisible)")

            guard self.isPanelVisible else { return }

            // ESC 键的 keyCode 是 53
            if event.keyCode == 53 {
                Logger.operation("ESC按键", detail: "全局ESC按下，关闭面板")
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
            Logger.operation("ESC监听器", detail: "全局监听器创建成功")
        } else {
            Logger.operation("ESC监听器", detail: "全局监听器创建失败")
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
            Logger.operation("本地键盘", detail: "keyCode=\(event.keyCode), isRepeat=\(event.isARepeat), isPanelVisible=\(self.isPanelVisible)")

            guard self.isPanelVisible else { return event }

            // ESC 键的 keyCode 是 53
            if event.keyCode == 53 {
                Logger.operation("ESC按键", detail: "本地ESC按下，关闭面板")
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
            Logger.operation("ESC监听器", detail: "本地监听器创建成功")
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
        // 操作日志：面板隐藏
        Logger.panelState("隐藏", detail: "wasSwitchModifierPressed=\(wasSwitchModifierPressed)")

        // 立即标记面板不可见，避免状态不一致
        isPanelVisible = false

        // 重置修饰键状态，避免重复触发
        wasSwitchModifierPressed = false

        // 恢复焦点轮询
        windowManager.resumeFocusPolling()

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
            Logger.info("Switch panel hidden")
        }
    }
}
