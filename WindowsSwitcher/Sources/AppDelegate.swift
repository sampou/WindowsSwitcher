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

    // 显示程序坞预览面板
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

        // 获取预览面板应该显示的位置
        let screenFrame = NSScreen.main?.frame ?? .zero
        let dockFrame = DockGeometry.getDockFrame()

        let previewPosition = CGPoint(
            x: screenFrame.midX,
            y: dockFrame.maxY + 80
        )

        // 创建简单的预览视图
        let previewContainer = createPreviewContainer()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .titled],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = NSColor.white
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = previewContainer

        // 设置窗口位置
        panel.setFrameOrigin(NSPoint(
            x: previewPosition.x - 200,
            y: previewPosition.y - 75
        ))

        panel.orderFront(nil)

        dockPreviewWindow = panel
    }

    // 隐藏程序坞预览面板
    @MainActor
    private func hideDockPreviewPanel() {
        guard let window = dockPreviewWindow else { return }
        window.orderOut(nil)
        dockPreviewWindow = nil
        Logger.info("Dock preview window hidden")
    }

    // 创建预览容器视图（使用 NSView 代替 SwiftUI）
    private func createPreviewContainer() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor

        let items = DockPreviewManager.shared.previewItems
        let spacing: CGFloat = 8

        for (index, item) in items.prefix(4).enumerated() {
            let x = CGFloat(index) * (104 + spacing)
            let itemView = createItemView(for: item, index: index)
            itemView.frame = NSRect(x: x, y: 8, width: 104, height: 134)
            container.addSubview(itemView)
        }

        return container
    }

    // 创建单个预览项视图
    private func createItemView(for item: DockPreviewItem, index: Int) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 104, height: 134))
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor

        // 异步加载预览图
        Task {
            let generator = item.previewGenerator ?? DockPreviewManager.shared.previewGenerator
            let size = CGSize(width: 100, height: 70)
            if let image = await generator.generatePreview(for: item.windowModel, size: size) {
                await MainActor.run {
                    self.addImageToView(view, image: image)
                }
            }
        }

        // 添加标题
        let titleLabel = NSTextField(labelWithString: item.windowTitle)
        titleLabel.frame = NSRect(x: 2, y: 2, width: 100, height: 16)
        titleLabel.font = NSFont.systemFont(ofSize: 10)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        view.addSubview(titleLabel)

        return view
    }

    // 将图片添加到视图
    private func addImageToView(_ view: NSView, image: NSImage) {
        let imageView = NSImageView(frame: NSRect(x: 2, y: 18, width: 100, height: 70))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        view.addSubview(imageView)
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
        let windows = windowManager.getAllWindows()
        Logger.info("==> getAllWindows: \((CFAbsoluteTimeGetCurrent() - t0)*1000)ms, count: \(windows.count)")

        // 3. 按最近活跃时间排序（最新的在前），并将当前前台应用的窗口放在最前面
        let t1 = CFAbsoluteTimeGetCurrent()
        // 获取当前前台应用的 bundleIdentifier
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        var sortedWindows: [WindowModel]
        if let frontID = frontmostBundleID {
            // 分离当前前台应用的窗口和其他窗口
            let frontmostWindows = windows.filter { $0.bundleIdentifier == frontID }
            let otherWindows = windows.filter { $0.bundleIdentifier != frontID }
            // 前台窗口按活跃时间排序，其他窗口也按活跃时间排序
            let sortedFront = frontmostWindows.sorted { $0.lastActiveTime > $1.lastActiveTime }
            let sortedOther = otherWindows.sorted { $0.lastActiveTime > $1.lastActiveTime }
            sortedWindows = sortedFront + sortedOther
            Logger.info("==> sort windows: frontmost=\(frontID), frontmostCount=\(frontmostWindows.count)")
        } else {
            sortedWindows = windows.sorted { $0.lastActiveTime > $1.lastActiveTime }
        }
        Logger.info("==> sort windows: \((CFAbsoluteTimeGetCurrent() - t1)*1000)ms")

        let t2 = CFAbsoluteTimeGetCurrent()
        let vm = SwitchPanelViewModel(
            windows: sortedWindows,
            windowManager: windowManager,
            previewGenerator: previewGenerator,
            filterEngine: filterEngine
        )
        Logger.info("==> SwitchPanelViewModel created: \((CFAbsoluteTimeGetCurrent() - t2)*1000)ms")
        if reversed { vm.selectPrevious() }

        // 保存 viewModel 引用，用于 Option 键释放时激活窗口
        self.switchPanelViewModel = vm

        // 4. 启动定时器定期刷新窗口列表（实时更新）
        startWindowRefreshTimer(for: vm)

        let t3 = CFAbsoluteTimeGetCurrent()
        let view = SwitchPanelView(viewModel: vm) { [weak self] in
            self?.hideSwitchPanel()
        }
        Logger.info("==> SwitchPanelView created: \((CFAbsoluteTimeGetCurrent() - t3)*1000)ms")

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Panel.width, height: DesignTokens.Panel.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: view)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.center()
        PanelAnimator.show(panel)
        switchPanelWindow = panel

        // 设置 ESC 键全局监听器
        setupEscKeyMonitor()

        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        Logger.info("==> showSwitchPanel TOTAL: \(totalTime)ms, \(sortedWindows.count) windows")
    }

    // 设置 ESC 键全局监听器
    private func setupEscKeyMonitor() {
        // 先移除旧的监听器
        removeEscKeyMonitor()

        Logger.info("==> Setting up ESC key monitor")

        // 使用全局监听器
        globalEscKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Logger.info("==> Global keyDown: keyCode=\(event.keyCode)")
            guard let self, self.isPanelVisible else { return }

            // ESC 键的 keyCode 是 53
            if event.keyCode == 53 {
                Logger.info("==> Global ESC pressed, hiding panel")
                Task { @MainActor in
                    self.hideSwitchPanel()
                }
            }
        }

        if globalEscKeyMonitor != nil {
            Logger.info("==> ESC key monitor created successfully")
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
            Logger.info("==> Local keyDown: keyCode=\(event.keyCode)")
            guard let self, self.isPanelVisible else { return event }

            // ESC 键的 keyCode 是 53
            if event.keyCode == 53 {
                Logger.info("==> Local ESC pressed, hiding panel")
                Task { @MainActor in
                    self.hideSwitchPanel()
                }
                return nil // 阻止事件继续传递
            }
            return event
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
