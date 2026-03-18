import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var switchPanelWindow: NSWindow?
    private let windowManager = WindowManager()
    private let previewGenerator = PreviewGenerator()
    private let filterEngine = FilterEngine()
    private let configManager = ConfigManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        requestPermissions()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Window Switcher")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
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

    func showSwitchPanel() {
        let windows = windowManager.getAllWindows()
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: windowManager,
            previewGenerator: previewGenerator,
            filterEngine: filterEngine
        )
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
    }

    func hideSwitchPanel() {
        switchPanelWindow?.orderOut(nil)
        switchPanelWindow = nil
    }
}
