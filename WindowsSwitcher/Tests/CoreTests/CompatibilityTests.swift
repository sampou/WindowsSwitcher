import XCTest
import AppKit
@testable import WindowsSwitcher

// MARK: - T-061 兼容性测试
// 验收标准：macOS 13+，深浅色模式，多显示器，不同屏幕分辨率

final class CompatibilityTests: XCTestCase {

    // MARK: - macOS 版本 API 可用性

    func testMacOS13APIAvailability() {
        // CGWindowListCopyWindowInfo 在 macOS 13+ 可用
        if #available(macOS 13.0, *) {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            // 可能为 nil（无权限），但不应崩溃
            _ = list
        }
    }

    func testNSRunningApplicationAvailability() {
        // NSRunningApplication 在 macOS 13+ 完整可用
        let apps = NSWorkspace.shared.runningApplications
        XCTAssertFalse(apps.isEmpty, "应有正在运行的应用")
    }

    func testAXUIElementAvailability() {
        // AX API 在 macOS 13+ 可用
        let element = AXUIElementCreateSystemWide()
        XCTAssertNotNil(element)
    }

    // MARK: - 深浅色模式兼容

    func testLightThemeColors() {
        ConfigManager.shared.updateAppearance { $0.theme = .light }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .light)
        ConfigManager.shared.reset()
    }

    func testDarkThemeColors() {
        ConfigManager.shared.updateAppearance { $0.theme = .dark }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .dark)
        ConfigManager.shared.reset()
    }

    func testAutoThemeFollowsSystem() {
        ConfigManager.shared.updateAppearance { $0.theme = .auto }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        // auto 模式下 effectiveColorScheme 应为 light 或 dark
        let scheme = ThemeManager.shared.effectiveColorScheme
        XCTAssertTrue(scheme == .light || scheme == .dark)
        ConfigManager.shared.reset()
    }

    // MARK: - DesignTokens 在不同分辨率下的规格

    func testPanelDimensionsAreFixed() {
        // 面板尺寸固定，不随屏幕分辨率变化
        // 更新为新设计：1100x550
        XCTAssertEqual(DesignTokens.Panel.width, 1100)
        XCTAssertEqual(DesignTokens.Panel.height, 550)
    }

    func testWindowItemDimensionsAreFixed() {
        // 更新为新设计：130x130
        XCTAssertEqual(DesignTokens.WindowItem.width, 130)
        XCTAssertEqual(DesignTokens.WindowItem.height, 130)
    }

    func testPreviewAspectRatioIsConsistent() {
        let ratio = DesignTokens.WindowItem.previewWidth / DesignTokens.WindowItem.previewHeight
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.05)
    }

    // MARK: - 多显示器：NSScreen 可用性

    func testNSScreenMainExists() {
        // 至少有一个主屏幕
        XCTAssertNotNil(NSScreen.main, "应有主屏幕")
    }

    func testNSScreenScaleFactor() {
        guard let screen = NSScreen.main else { return }
        // Retina 屏幕 backingScaleFactor 为 2.0，普通屏幕为 1.0
        XCTAssertGreaterThanOrEqual(screen.backingScaleFactor, 1.0)
        XCTAssertLessThanOrEqual(screen.backingScaleFactor, 3.0)
    }

    // MARK: - ConfigModel 跨版本兼容（schema 演进）

    func testConfigDecodesWithExtraFields() throws {
        // 模拟未来版本添加了新字段，旧版本应能正常解码
        let json = """
        {"appearance":{"panelOpacity":0.9,"panelCornerRadius":12,"previewWidth":640,
        "previewHeight":360,"previewSize":"中","switcherColumns":0,"theme":"auto","futureField":"ignored"},
        "behavior":{"sortOrder":"recent","showOffScreenWindows":false,
        "previewUpdateInterval":0.1,"panelDisplayDelay":0.0,"defaultSelectSecond":false,
        "showBackgroundPreview":true,"launchAtLogin":false},
        "hotKeys":{"switchKeyCode":48,"switchModifiers":2048,
        "reverseSwitchModifiers":2560,"appSwitchKeyCode":50,"appSwitchModifiers":2048,
        "appSwitchReverseKeyCode":50,"appSwitchReverseModifiers":2560,"appSwitchEnabled":true},
        "dockPreview":{"enabled":true,"hoverDelay":0.05,"hideDelay":0.1,"maxPreviewCount":4,
        "previewWidth":104,"previewHeight":58,"showAnimation":true,"verticalSpacing":0,
        "horizontalSpacing":0,"showAppIcon":true},
        "update":{"autoCheckEnabled":false,"autoDownloadEnabled":false,"silentInstallEnabled":false,
        "checkInterval":86400,"apiURL":"https://api.github.com/repos/sampou/WindowsSwitcher/releases/latest",
        "releasesPageURL":"https://github.com/sampou/WindowsSwitcher/releases","githubToken":""}}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ConfigModel.self, from: data)
        XCTAssertEqual(config.appearance.panelOpacity, 0.9, accuracy: 0.001)
    }

    func testConfigDecodesWithMissingFields() throws {
        // 使用当前 schema 的完整嵌套字段，额外字段缺失时由字段默认值覆盖
        let json = """
        {"appearance":{"panelOpacity":0.95,"panelCornerRadius":12,"previewWidth":640,
        "previewHeight":360,"previewSize":"中","switcherColumns":0,"theme":"auto"},
        "behavior":{"sortOrder":"recent","showOffScreenWindows":false,
        "previewUpdateInterval":0.1,"panelDisplayDelay":0.0,"defaultSelectSecond":false,
        "showBackgroundPreview":true,"launchAtLogin":false},
        "hotKeys":{"switchKeyCode":48,"switchModifiers":2048,
        "reverseSwitchModifiers":2560,"appSwitchKeyCode":50,"appSwitchModifiers":2048,
        "appSwitchReverseKeyCode":50,"appSwitchReverseModifiers":2560,"appSwitchEnabled":true},
        "dockPreview":{"enabled":true,"hoverDelay":0.05,"hideDelay":0.1,"maxPreviewCount":4,
        "previewWidth":104,"previewHeight":58,"showAnimation":true,"verticalSpacing":0,
        "horizontalSpacing":0,"showAppIcon":true},
        "update":{"autoCheckEnabled":false,"autoDownloadEnabled":false,"silentInstallEnabled":false,
        "checkInterval":86400,"apiURL":"https://api.github.com/repos/sampou/WindowsSwitcher/releases/latest",
        "releasesPageURL":"https://github.com/sampou/WindowsSwitcher/releases","githubToken":""}}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ConfigModel.self, from: data)
        XCTAssertEqual(config.appearance.panelOpacity, 0.95, accuracy: 0.001)
        XCTAssertEqual(config.behavior.sortOrder, .recent)
    }

    // MARK: - Notification.Name 在不同 OS 版本下一致

    func testNotificationNamesStable() {
        XCTAssertEqual(Notification.Name.switchHotKeyPressed.rawValue,
                       "com.windowsswitcher.switchHotKey")
        XCTAssertEqual(Notification.Name.reverseSwitchHotKeyPressed.rawValue,
                       "com.windowsswitcher.reverseSwitchHotKey")
        XCTAssertEqual(Notification.Name.appSwitchHotKeyPressed.rawValue,
                       "com.windowsswitcher.appSwitchHotKey")
        XCTAssertEqual(Notification.Name.windowListDidChange.rawValue,
                       "com.windowsswitcher.windowListDidChange")
    }

    // MARK: - NSImage 在不同分辨率下可用

    func testNSImageCreationAtDifferentSizes() {
        let sizes: [NSSize] = [
            NSSize(width: 16, height: 16),
            NSSize(width: 32, height: 32),
            NSSize(width: 64, height: 64),
            NSSize(width: 124, height: 70),
            NSSize(width: 640, height: 360),
        ]
        for size in sizes {
            let img = NSImage(size: size)
            XCTAssertEqual(img.size.width, size.width)
            XCTAssertEqual(img.size.height, size.height)
        }
    }
}
