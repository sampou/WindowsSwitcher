import AppKit
import SwiftUI
import Carbon
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var switchPanelWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
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
            // 防止快速触发（100ms内不重复触发）
            let now = Date()
            guard now.timeIntervalSince(self.lastHotKeyTime) > 0.1 else { return }
            self.lastHotKeyTime = now
            DispatchQueue.main.async {
                if self.isPanelVisible {
                    NotificationCenter.default.post(name: .switchHotKeyPressed, object: nil)
                } else {
                    Task { @MainActor in self.showSwitchPanel() }
                }
            }
        }

        // Option+Shift+Tab: 反向切换
        hotKeyManager.register(
            HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey), identifier: "reverseSwitch")
        ) { [weak self] in
            guard let self else { return }
            // 防止快速触发（100ms内不重复触发）
            let now = Date()
            guard now.timeIntervalSince(self.lastHotKeyTime) > 0.1 else { return }
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
        let windows = windowManager.getAllWindows()

        // 3. 按最近活跃时间排序（最新的在前）
        let sortedWindows = windows.sorted { $0.lastActiveTime > $1.lastActiveTime }

        let vm = SwitchPanelViewModel(
            windows: sortedWindows,
            windowManager: windowManager,
            previewGenerator: previewGenerator,
            filterEngine: filterEngine
        )
        if reversed { vm.selectPrevious() }

        // 保存 viewModel 引用，用于 Option 键释放时激活窗口
        self.switchPanelViewModel = vm

        // 4. 启动定时器定期刷新窗口列表（实时更新）
        startWindowRefreshTimer(for: vm)

        let view = SwitchPanelView(viewModel: vm) { [weak self] in
            self?.hideSwitchPanel()
        }
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

        Logger.info("Switch panel shown, \(sortedWindows.count) windows, sorted by lastActiveTime")
    }

    // 定时刷新窗口列表
    private var windowRefreshTimer: Timer?

    private func startWindowRefreshTimer(for vm: SwitchPanelViewModel) {
        // 停止之前的定时器
        windowRefreshTimer?.invalidate()

        // 每 200ms 刷新一次窗口列表，确保实时更新
        windowRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak vm] _ in
            guard let self, let vm = self.switchPanelViewModel else { return }
            // 刷新窗口列表
            let freshWindows = self.windowManager.getAllWindows()
            let sorted = freshWindows.sorted { $0.lastActiveTime > $1.lastActiveTime }

            Task { @MainActor in
                vm.updateWindows(sorted)
            }
        }
    }

    private func stopWindowRefreshTimer() {
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil
    }

    func hideSwitchPanel() {
        // 停止刷新定时器
        stopWindowRefreshTimer()

        guard let panel = switchPanelWindow else { return }
        PanelAnimator.hide(panel) { [weak self] in
            self?.switchPanelWindow = nil
            self?.isPanelVisible = false
            Logger.info("Switch panel hidden")
        }
    }
}
