import XCTest
import Combine
@testable import WindowsSwitcher

// MARK: - T-039 ConfigManager 完整测试

final class ConfigManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConfigManager.shared.reset()
    }

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
    }

    // MARK: - updateAppearance

    func testUpdateAppearancePanelOpacity() {
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.5 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.panelOpacity, 0.5, accuracy: 0.001)
    }

    func testUpdateAppearanceTheme() {
        ConfigManager.shared.updateAppearance { $0.theme = .dark }
        XCTAssertEqual(ConfigManager.shared.config.appearance.theme, .dark)
    }

    func testUpdateAppearanceCornerRadius() {
        ConfigManager.shared.updateAppearance { $0.panelCornerRadius = 16 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.panelCornerRadius, 16, accuracy: 0.001)
    }

    func testUpdateAppearancePreviewSize() {
        ConfigManager.shared.updateAppearance { $0.previewWidth = 800; $0.previewHeight = 450 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.previewWidth, 800, accuracy: 0.001)
        XCTAssertEqual(ConfigManager.shared.config.appearance.previewHeight, 450, accuracy: 0.001)
    }

    // MARK: - updateBehavior

    func testUpdateBehaviorSortOrder() {
        ConfigManager.shared.updateBehavior { $0.sortOrder = .appName }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .appName)
    }

    func testUpdateBehaviorShowMinimized() {
        ConfigManager.shared.updateBehavior { $0.showMinimizedWindows = false }
        XCTAssertFalse(ConfigManager.shared.config.behavior.showMinimizedWindows)
    }

    func testUpdateBehaviorShowHidden() {
        ConfigManager.shared.updateBehavior { $0.showHiddenWindows = true }
        XCTAssertTrue(ConfigManager.shared.config.behavior.showHiddenWindows)
    }

    func testUpdateBehaviorPreviewInterval() {
        ConfigManager.shared.updateBehavior { $0.previewUpdateInterval = 0.5 }
        XCTAssertEqual(ConfigManager.shared.config.behavior.previewUpdateInterval, 0.5, accuracy: 0.001)
    }

    func testUpdateBehaviorPanelDisplayDelay() {
        ConfigManager.shared.updateBehavior { $0.panelDisplayDelay = 0.2 }
        XCTAssertEqual(ConfigManager.shared.config.behavior.panelDisplayDelay, 0.2, accuracy: 0.001)
    }

    // MARK: - updateHotKeys

    func testUpdateHotKeysSwitchKeyCode() {
        ConfigManager.shared.updateHotKeys { $0.switchKeyCode = 36 }
        XCTAssertEqual(ConfigManager.shared.config.hotKeys.switchKeyCode, 36)
    }

    func testUpdateHotKeysSwitchModifiers() {
        ConfigManager.shared.updateHotKeys { $0.switchModifiers = 512 }
        XCTAssertEqual(ConfigManager.shared.config.hotKeys.switchModifiers, 512)
    }

    func testUpdateHotKeysAppSwitchKeyCode() {
        ConfigManager.shared.updateHotKeys { $0.appSwitchKeyCode = 49 }
        XCTAssertEqual(ConfigManager.shared.config.hotKeys.appSwitchKeyCode, 49)
    }

    func testUpdateHotKeysReverseSwitchModifiers() {
        ConfigManager.shared.updateHotKeys { $0.reverseSwitchModifiers = 262144 }
        XCTAssertEqual(ConfigManager.shared.config.hotKeys.reverseSwitchModifiers, 262144)
    }

    // MARK: - reset

    func testResetRestoresAllDefaults() {
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.1; $0.theme = .dark }
        ConfigManager.shared.updateBehavior { $0.sortOrder = .windowTitle; $0.showMinimizedWindows = false }
        ConfigManager.shared.updateHotKeys { $0.switchKeyCode = 99 }
        ConfigManager.shared.reset()
        let c = ConfigManager.shared.config
        XCTAssertEqual(c.appearance.panelOpacity, 0.95, accuracy: 0.001)
        XCTAssertEqual(c.appearance.theme, .auto)
        XCTAssertEqual(c.behavior.sortOrder, .recent)
        XCTAssertTrue(c.behavior.showMinimizedWindows)
        XCTAssertEqual(c.hotKeys.switchKeyCode, 48)
    }

    // MARK: - Persistence round-trip

    func testConfigPersistsAfterSave() throws {
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.77 }
        let data = try JSONEncoder().encode(ConfigManager.shared.config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)
        XCTAssertEqual(decoded.appearance.panelOpacity, 0.77, accuracy: 0.001)
    }

    // MARK: - @Published fires on change

    func testConfigPublishedFiresOnChange() {
        let exp = expectation(description: "config published")
        var count = 0
        let cancellable = ConfigManager.shared.$config
            .dropFirst()
            .sink { _ in count += 1; if count == 1 { exp.fulfill() } }
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.3 }
        waitForExpectations(timeout: 1.0)
        cancellable.cancel()
    }
}

// MARK: - ConfigModel 子结构体默认值测试

final class ConfigModelSubstructTests: XCTestCase {

    func testHotKeyConfigDefaults() {
        let hk = HotKeyConfig()
        XCTAssertEqual(hk.switchKeyCode, 48)
        XCTAssertEqual(hk.switchModifiers, 256)
        XCTAssertEqual(hk.reverseSwitchModifiers, 131072)
        XCTAssertEqual(hk.appSwitchKeyCode, 50)
        XCTAssertEqual(hk.appSwitchModifiers, 256)
    }

    func testAppearanceConfigDefaults() {
        let a = AppearanceConfig()
        XCTAssertEqual(a.panelOpacity, 0.95, accuracy: 0.001)
        XCTAssertEqual(a.panelCornerRadius, 12, accuracy: 0.001)
        XCTAssertEqual(a.previewWidth, 640, accuracy: 0.001)
        XCTAssertEqual(a.previewHeight, 360, accuracy: 0.001)
        XCTAssertEqual(a.theme, .auto)
    }

    func testBehaviorConfigDefaults() {
        let b = BehaviorConfig()
        XCTAssertEqual(b.sortOrder, .recent)
        XCTAssertTrue(b.showMinimizedWindows)
        XCTAssertFalse(b.showHiddenWindows)
        XCTAssertEqual(b.previewUpdateInterval, 0.1, accuracy: 0.001)
        XCTAssertEqual(b.panelDisplayDelay, 0.0, accuracy: 0.001)
    }

    func testConfigModelEquality() {
        let c1 = ConfigModel()
        let c2 = ConfigModel()
        XCTAssertEqual(c1, c2)
    }

    func testConfigModelInequalityAfterChange() {
        var c1 = ConfigModel()
        let c2 = ConfigModel()
        c1.appearance.panelOpacity = 0.1
        XCTAssertNotEqual(c1, c2)
    }

    func testAppThemeAllCases() {
        XCTAssertEqual(AppTheme.allCases.count, 3)
        XCTAssertTrue(AppTheme.allCases.contains(.light))
        XCTAssertTrue(AppTheme.allCases.contains(.dark))
        XCTAssertTrue(AppTheme.allCases.contains(.auto))
    }

    func testSortOrderAllCases() {
        XCTAssertEqual(SortOrder.allCases.count, 3)
        XCTAssertTrue(SortOrder.allCases.contains(.recent))
        XCTAssertTrue(SortOrder.allCases.contains(.appName))
        XCTAssertTrue(SortOrder.allCases.contains(.windowTitle))
    }

    func testAppThemeRawValues() {
        XCTAssertEqual(AppTheme.light.rawValue, "light")
        XCTAssertEqual(AppTheme.dark.rawValue, "dark")
        XCTAssertEqual(AppTheme.auto.rawValue, "auto")
    }

    func testSortOrderRawValues() {
        XCTAssertEqual(SortOrder.recent.rawValue, "recent")
        XCTAssertEqual(SortOrder.appName.rawValue, "appName")
        XCTAssertEqual(SortOrder.windowTitle.rawValue, "windowTitle")
    }

    func testHotKeyConfigEquality() {
        let hk1 = HotKeyConfig()
        let hk2 = HotKeyConfig()
        XCTAssertEqual(hk1, hk2)
    }

    func testAppearanceConfigEquality() {
        let a1 = AppearanceConfig()
        var a2 = AppearanceConfig()
        XCTAssertEqual(a1, a2)
        a2.theme = .dark
        XCTAssertNotEqual(a1, a2)
    }

    func testBehaviorConfigEquality() {
        let b1 = BehaviorConfig()
        var b2 = BehaviorConfig()
        XCTAssertEqual(b1, b2)
        b2.sortOrder = .appName
        XCTAssertNotEqual(b1, b2)
    }

    func testConfigModelEncodeDecodeAllFields() throws {
        var config = ConfigModel()
        config.appearance.theme = .dark
        config.appearance.panelOpacity = 0.8
        config.behavior.sortOrder = .windowTitle
        config.behavior.showHiddenWindows = true
        config.hotKeys.switchKeyCode = 36

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)

        XCTAssertEqual(decoded.appearance.theme, .dark)
        XCTAssertEqual(decoded.appearance.panelOpacity, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.behavior.sortOrder, .windowTitle)
        XCTAssertTrue(decoded.behavior.showHiddenWindows)
        XCTAssertEqual(decoded.hotKeys.switchKeyCode, 36)
    }
}
