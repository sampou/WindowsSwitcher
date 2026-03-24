import AppKit
import SwiftUI
import Carbon

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保作为菜单栏应用运行，不显示 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        requestPermissions()
        setupHotKeys()
        // 监听 Option 键释放，当面板显示时自动切换并关闭
        setupOptionKeyMonitor()
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
        if !hasScreen { CGRequestScreenCaptureAccess() }
        if !hasTrusted || !hasScreen {
            updateMenuBarIcon(hasPermissions: false)
            Logger.warning("Missing permissions - Accessibility: \(hasTrusted), Screen Recording: \(hasScreen)")
        } else {
            updateMenuBarIcon(hasPermissions: true)
            Logger.info("All permissions granted")
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

        let windows = windowManager.getAllWindows()
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: windowManager,
            previewGenerator: previewGenerator,
            filterEngine: filterEngine
        )
        if reversed { vm.selectPrevious() }
        // 刷新窗口列表，确保显示最新的活动窗口
        vm.refreshWindows()
        // 保存 viewModel 引用，用于 Option 键释放时激活窗口
        self.switchPanelViewModel = vm

        let view = SwitchPanelView(viewModel: vm) { [weak self] in
            self?.hideSwitchPanel()
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Panel.width, height: DesignTokens.Panel.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        PanelAnimator.show(panel)
        switchPanelWindow = panel

        Logger.info("Switch panel shown, \(windows.count) windows")
    }

    func hideSwitchPanel() {
        guard let panel = switchPanelWindow else { return }
        PanelAnimator.hide(panel) { [weak self] in
            self?.switchPanelWindow = nil
            self?.isPanelVisible = false
            Logger.info("Switch panel hidden")
        }
    }
}
