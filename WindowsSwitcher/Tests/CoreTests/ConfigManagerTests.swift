import XCTest
import Combine
import AppKit
import Carbon
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

    func testUpdateBehaviorShowOffScreenDisabled() {
        ConfigManager.shared.updateBehavior { $0.showOffScreenWindows = false }
        XCTAssertFalse(ConfigManager.shared.config.behavior.showOffScreenWindows)
    }

    func testUpdateBehaviorShowOffScreenEnabled() {
        ConfigManager.shared.updateBehavior { $0.showOffScreenWindows = true }
        XCTAssertTrue(ConfigManager.shared.config.behavior.showOffScreenWindows)
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
        ConfigManager.shared.updateBehavior { $0.sortOrder = .windowTitle; $0.showOffScreenWindows = true }
        ConfigManager.shared.updateHotKeys { $0.switchKeyCode = 99 }
        ConfigManager.shared.reset()
        let c = ConfigManager.shared.config
        XCTAssertEqual(c.appearance.panelOpacity, 0.95, accuracy: 0.001)
        XCTAssertEqual(c.appearance.theme, .auto)
        XCTAssertEqual(c.behavior.sortOrder, .recent)
        XCTAssertFalse(c.behavior.showOffScreenWindows)
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

    func testLayoutChordConvertsToNativeMenuShortcut() {
        let chord = KeyChord(
            keyCode: UInt32(kVK_LeftArrow),
            modifiers: UInt32(controlKey | optionKey | cmdKey)
        )

        XCTAssertEqual(chord.menuKeyEquivalent, UnicodeScalar(NSLeftArrowFunctionKey).map(String.init))
        XCTAssertEqual(chord.menuModifierMask, [.control, .option, .command])
    }

    func testUnknownKeyCodeOmitsNativeMenuShortcut() {
        let chord = KeyChord(keyCode: UInt32.max, modifiers: UInt32(controlKey))

        XCTAssertNil(chord.menuKeyEquivalent)
        XCTAssertEqual(chord.menuModifierMask, [.control])
    }

    func testHotKeyConfigDefaults() {
        let hk = HotKeyConfig()
        XCTAssertEqual(hk.switchKeyCode, 48)
        XCTAssertEqual(hk.switchModifiers, 2048)
        XCTAssertEqual(hk.reverseSwitchModifiers, 2560)
        XCTAssertEqual(hk.appSwitchKeyCode, 50)
        XCTAssertEqual(hk.appSwitchModifiers, 2048)
        XCTAssertTrue(hk.windowLayout.isEnabled)
        XCTAssertEqual(hk.windowLayout.openPanel, WindowLayoutHotKeyDefaults.openPanel)
        XCTAssertEqual(hk.windowLayout.commands.count, 12)
    }

    func testOldHotKeyJSONInjectsWindowLayoutDefaults() throws {
        let json = """
        {
          "switchKeyCode": 48,
          "switchModifiers": 2048,
          "appSwitchKeyCode": 50,
          "appSwitchModifiers": 2048
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(HotKeyConfig.self, from: json)

        XCTAssertEqual(decoded.windowLayout, WindowLayoutHotKeyConfig())
    }

    // MARK: - 旧配置向前兼容解码（商业化升级时设置不能丢）

    func testLegacyConfigJSONMissingSectionsDecodesWithDefaults() throws {
        // 早期版本只保存了部分顶层段落：新版本解码不能整体失败
        let json = """
        {
          "hotKeys": {"switchKeyCode": 48, "switchModifiers": 2048},
          "appearance": {"panelOpacity": 0.8}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ConfigModel.self, from: json)

        XCTAssertEqual(decoded.appearance.panelOpacity, 0.8, accuracy: 0.001, "已有段落要保留")
        XCTAssertEqual(decoded.behavior.sortOrder, .recent, "缺失段落要回落默认值")
        XCTAssertEqual(decoded.dockPreview.maxPreviewCount, 4, "缺失段落要回落默认值")
        XCTAssertEqual(decoded.update.checkInterval, 86400, "缺失段落要回落默认值")
    }

    func testLegacyDockPreviewConfigJSONMissingFieldsDecodesWithDefaults() throws {
        let json = """
        {
          "enabled": false,
          "hoverDelay": 0.2
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DockPreviewConfig.self, from: json)

        XCTAssertFalse(decoded.enabled, "已有字段要保留")
        XCTAssertEqual(decoded.hoverDelay, 0.2, accuracy: 0.001, "已有字段要保留")
        XCTAssertTrue(decoded.showAppIcon, "缺失字段要回落默认值")
        XCTAssertEqual(decoded.maxPreviewCount, 4, "缺失字段要回落默认值")
    }

    func testLegacyUpdateConfigJSONMissingFieldsDecodesWithDefaults() throws {
        let json = """
        {"autoCheckEnabled": true}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UpdateConfig.self, from: json)

        XCTAssertTrue(decoded.autoCheckEnabled)
        XCTAssertEqual(decoded.checkInterval, 86400)
        XCTAssertFalse(decoded.silentInstallEnabled)
    }

    func testNewConfigJSONDecodesWithUnknownExtraFieldsIgnored() throws {
        // 新版本配置被旧版本读取时多出的字段应被忽略而不是报错
        let json = """
        {"hotKeys": {}, "appearance": {}, "behavior": {}, "dockPreview": {}, "update": {}, "futureSection": {"x": 1}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ConfigModel.self, from: json)
        XCTAssertEqual(decoded.hotKeys.switchKeyCode, 48)
    }

    func testClearedLayoutShortcutRemainsClearedAfterRoundTrip() throws {
        var value = WindowLayoutHotKeyConfig()
        value.setChord(nil, for: .leftHalf)
        let data = try JSONEncoder().encode(value)

        let decoded = try JSONDecoder().decode(WindowLayoutHotKeyConfig.self, from: data)

        XCTAssertNil(decoded.chord(for: .leftHalf))
        XCTAssertEqual(decoded.chord(for: .rightHalf), value.chord(for: .rightHalf))
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
        XCTAssertFalse(b.showOffScreenWindows)
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
        XCTAssertEqual(SortOrder.allCases.count, 4)
        XCTAssertTrue(SortOrder.allCases.contains(.recent))
        XCTAssertTrue(SortOrder.allCases.contains(.appName))
        XCTAssertTrue(SortOrder.allCases.contains(.windowTitle))
        XCTAssertTrue(SortOrder.allCases.contains(.appGroup))
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
        config.behavior.showOffScreenWindows = true
        config.hotKeys.switchKeyCode = 36

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)

        XCTAssertEqual(decoded.appearance.theme, .dark)
        XCTAssertEqual(decoded.appearance.panelOpacity, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.behavior.sortOrder, .windowTitle)
        XCTAssertTrue(decoded.behavior.showOffScreenWindows)
        XCTAssertEqual(decoded.hotKeys.switchKeyCode, 36)
    }
}
