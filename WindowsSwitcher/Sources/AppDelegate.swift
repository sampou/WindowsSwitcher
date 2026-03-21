import AppKit
import SwiftUI
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var switchPanelWindow: NSWindow?
    private let windowManager = WindowManager()
    private let previewGenerator = PreviewGenerator()
    private let filterEngine = FilterEngine()
    private let configManager = ConfigManager.shared
    private let hotKeyManager = HotKeyManager()
    private var isPanelVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保作为菜单栏应用运行，不显示 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        requestPermissions()
        setupHotKeys()
    }

    // MARK: - 快捷键注册
    private func setupHotKeys() {
        // Cmd+Tab: 显示/下一个
        hotKeyManager.register(
            HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey), identifier: "switch")
        ) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.isPanelVisible {
                    NotificationCenter.default.post(name: .switchHotKeyPressed, object: nil)
                } else {
                    Task { @MainActor in self.showSwitchPanel() }
                }
            }
        }

        // Cmd+Shift+Tab: 反向切换
        hotKeyManager.register(
            HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey | shiftKey), identifier: "reverseSwitch")
        ) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.isPanelVisible {
                    NotificationCenter.default.post(name: .reverseSwitchHotKeyPressed, object: nil)
                } else {
                    Task { @MainActor in self.showSwitchPanel(reversed: true) }
                }
            }
        }

        // Cmd+`: 应用内切换
        hotKeyManager.register(
            HotKey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(cmdKey), identifier: "appSwitch")
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
            menu.addItem(NSMenuItem(title: "显示切换器", action: #selector(showSwitcherFromMenu), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ","))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        }
    }

    private func updateMenuBarIcon(hasPermissions: Bool) {
        let iconName = hasPermissions ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash"
        statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    }

    @objc private func openSettings() {
        // macOS 13: showPreferencesWindow:
        // macOS 14+: showSettingsWindow: 已被废弃，改用 openSettings: (公开 action)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("openSettings:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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
