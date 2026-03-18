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

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // 右键显示菜单
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "显示切换器", action: #selector(showSwitcherFromMenu), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ","))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            // 左键直接显示切换面板
            Task { @MainActor in self.showSwitchPanel() }
        }
    }

    @objc private func showSwitcherFromMenu() {
        Task { @MainActor in self.showSwitchPanel() }
    }

    private func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        CGRequestScreenCaptureAccess()
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
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
        panel.makeKeyAndOrderFront(nil)
        switchPanelWindow = panel

        Logger.info("Switch panel shown, \(windows.count) windows")
    }

    func hideSwitchPanel() {
        switchPanelWindow?.orderOut(nil)
        switchPanelWindow = nil
        isPanelVisible = false
        Logger.info("Switch panel hidden")
    }
}
