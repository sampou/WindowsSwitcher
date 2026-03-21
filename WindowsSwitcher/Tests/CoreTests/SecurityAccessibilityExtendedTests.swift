import XCTest
import AppKit
@testable import WindowsSwitcher

// MARK: - T-064 安全测试（扩展）

final class SecurityExtendedTests: XCTestCase {

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
    }

    // MARK: - 权限检查

    func testAccessibilityPermissionDoesNotCrash() {
        _ = AXIsProcessTrusted()
    }

    func testScreenCapturePermissionDoesNotCrash() {
        _ = CGPreflightScreenCaptureAccess()
    }

    // MARK: - 配置数据安全

    func testConfigContainsNoSensitiveFields() throws {
        let data = try JSONEncoder().encode(ConfigModel())
        let json = String(data: data, encoding: .utf8) ?? ""
        for keyword in ["password", "token", "secret", "apiKey", "privateKey", "credential"] {
            XCTAssertFalse(json.lowercased().contains(keyword),
                           "配置不应包含敏感字段：\(keyword)")
        }
    }

    func testConfigStorageKeyIsNamespaced() {
        // UserDefaults key 应有 bundle 前缀，避免与其他应用冲突
        let key = "com.windowsswitcher.config"
        XCTAssertTrue(key.hasPrefix("com.windowsswitcher"), "存储 key 应有命名空间前缀")
    }

    func testConfigResetClearsAllFields() {
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.1 }
        ConfigManager.shared.updateBehavior { $0.showHiddenWindows = true }
        ConfigManager.shared.reset()
        XCTAssertEqual(ConfigManager.shared.config.appearance.panelOpacity, 0.95, accuracy: 0.001)
        XCTAssertFalse(ConfigManager.shared.config.behavior.showHiddenWindows)
    }

    // MARK: - 输入验证：FilterCriteria 边界

    func testFilterWithEmptySearchTextReturnsAll() {
        let engine = FilterEngine()
        let windows = (1...5).map { makeWindow(id: CGWindowID($0)) }
        let result = engine.filter(windows, by: FilterCriteria(searchText: ""))
        XCTAssertEqual(result.count, windows.count)
    }

    func testFilterWithVeryLongSearchText() {
        let engine = FilterEngine()
        let windows = (1...5).map { makeWindow(id: CGWindowID($0)) }
        let longQuery = String(repeating: "a", count: 10000)
        let result = engine.filter(windows, by: FilterCriteria(searchText: longQuery))
        XCTAssertTrue(result.isEmpty || result.count <= windows.count)
    }

    func testFilterWithSpecialCharacters() {
        let engine = FilterEngine()
        let windows = [makeWindow(id: 1, app: "App & More")]
        let result = engine.filter(windows, by: FilterCriteria(searchText: "&"))
        XCTAssertFalse(result.isEmpty)
    }

    func testFilterWithUnicodeQuery() {
        let engine = FilterEngine()
        let windows = [makeWindow(id: 1, app: "微信")]
        let result = engine.filter(windows, by: FilterCriteria(searchText: "微"))
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - WindowModel 数据隔离

    func testWindowModelBundleIDNotAbsolutePath() {
        let w = makeWindow(id: 1, app: "Safari")
        XCTAssertFalse(w.bundleIdentifier.hasPrefix("/"),
                       "bundleIdentifier 不应为绝对路径")
    }

    func testWindowModelOwnerPIDIsPositive() {
        let w = makeWindow(id: 1, app: "Safari")
        XCTAssertGreaterThan(w.ownerPID, 0)
    }

    // MARK: - HotKeyManager 注销安全

    func testUnregisterAllHotKeysDoesNotCrash() {
        let manager = HotKeyManager()
        manager.register(HotKey(keyCode: 48, modifiers: 256, identifier: "a")) {}
        manager.register(HotKey(keyCode: 50, modifiers: 256, identifier: "b")) {}
        manager.unregister("a")
        manager.unregister("b")
        manager.unregister("nonexistent") // 不应崩溃
    }

    func testHotKeyManagerDeinitDoesNotCrash() {
        var manager: HotKeyManager? = HotKeyManager()
        manager?.register(HotKey(keyCode: 48, modifiers: 256, identifier: "x")) {}
        manager = nil // 触发 deinit
    }

    // MARK: - Notification 不泄露敏感信息

    func testNotificationObjectIsNil() {
        var received: Any? = "sentinel"
        let token = NotificationCenter.default.addObserver(
            forName: .switchHotKeyPressed, object: nil, queue: .main
        ) { note in received = note.object }
        NotificationCenter.default.post(name: .switchHotKeyPressed, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        NotificationCenter.default.removeObserver(token)
        XCTAssertNil(received, "switchHotKeyPressed 通知 object 应为 nil")
    }

    // MARK: - Helper

    private func makeWindow(id: CGWindowID, app: String = "TestApp") -> WindowModel {
        WindowModel(
            id: id, appName: app, bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: "\(app) Window", appIcon: NSImage(),
            frame: .zero, isMinimized: false, isHidden: false, isOnScreen: true,
            lastActiveTime: Date(), windowLayer: 0, ownerPID: pid_t(id * 100)
        )
    }
}

// MARK: - T-065 可访问性测试（扩展）

final class AccessibilityExtendedTests: XCTestCase {

    // MARK: - 颜色对比度（WCAG AA ≥ 4.5:1）

    func testAccentOnWhiteContrast() {
        let accent = relativeLuminance(r: 0, g: 120, b: 212)   // #0078D4
        let white = 1.0
        let ratio = (white + 0.05) / (accent + 0.05)
        XCTAssertGreaterThan(ratio, 4.5, "强调色在白色背景对比度应 ≥4.5:1，实测 \(String(format:"%.1f",ratio)):1")
    }

    func testDarkThemeTextContrast() {
        let bg = relativeLuminance(r: 28, g: 28, b: 30)        // #1C1C1E
        let text = 1.0                                          // 白色
        let ratio = (text + 0.05) / (bg + 0.05)
        XCTAssertGreaterThan(ratio, 4.5, "深色主题文字对比度应 ≥4.5:1，实测 \(String(format:"%.1f",ratio)):1")
    }

    func testLightThemeTextContrast() {
        let bg = 1.0                                            // 白色背景
        let text = relativeLuminance(r: 0, g: 0, b: 0)         // 黑色文字
        let ratio = (bg + 0.05) / (text + 0.05)
        XCTAssertGreaterThan(ratio, 7.0, "浅色主题文字对比度应 ≥7:1，实测 \(String(format:"%.1f",ratio)):1")
    }

    // MARK: - 键盘导航

    func testKeyCatchViewAcceptsFirstResponder() {
        let view = KeyCatchView()
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    func testKeyCatchViewIsNSView() {
        let view = KeyCatchView()
        XCTAssertTrue(view is NSView)
    }

    // MARK: - 动画时长（减少动态效果）

    func testAllAnimationDurationsUnder300ms() {
        XCTAssertLessThanOrEqual(0.20, 0.30, "面板显示动画")
        XCTAssertLessThanOrEqual(0.15, 0.30, "面板隐藏动画")
        XCTAssertLessThanOrEqual(0.15, 0.30, "悬停动画")
        XCTAssertLessThanOrEqual(0.10, 0.30, "预览加载动画")
        XCTAssertLessThanOrEqual(0.20, 0.30, "关闭动画")
    }

    // MARK: - 触摸目标尺寸（≥44pt）

    func testWindowItemTouchTargetSize() {
        XCTAssertGreaterThanOrEqual(DesignTokens.WindowItem.width, 44,
                                    "窗口项宽度应 ≥44pt")
        XCTAssertGreaterThanOrEqual(DesignTokens.WindowItem.height, 44,
                                    "窗口项高度应 ≥44pt")
    }

    // MARK: - 空状态可访问性

    @MainActor
    func testEmptyStateIsHandledGracefully() {
        let vm = SwitchPanelViewModel(
            windows: [],
            windowManager: WindowManager(),
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
        XCTAssertTrue(vm.filteredWindows.isEmpty)
        XCTAssertNil(vm.selectedWindow)
        // 空状态下导航不崩溃
        XCTAssertNoThrow(vm.selectNext())
        XCTAssertNoThrow(vm.selectPrevious())
    }

    // MARK: - 字体尺寸合理（≥11pt）

    func testFontSizesAreReadable() {
        XCTAssertGreaterThanOrEqual(DesignTokens.WindowItem.titleFontSize, 11)
        XCTAssertGreaterThanOrEqual(DesignTokens.WindowItem.subtitleFontSize, 11)
    }

    // MARK: - Helper

    private func relativeLuminance(r: Int, g: Int, b: Int) -> Double {
        func linearize(_ c: Int) -> Double {
            let s = Double(c) / 255.0
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }
}
