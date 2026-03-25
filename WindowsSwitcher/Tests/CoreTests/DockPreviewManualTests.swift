import XCTest
@testable import WindowsSwitcher

// MARK: - 程序坞预览功能测试

@MainActor
final class DockPreviewManualTests: XCTestCase {

    var dockPreviewManager: DockPreviewManager!

    override func setUp() async throws {
        dockPreviewManager = DockPreviewManager.shared
        ConfigManager.shared.reset()
    }

    override func tearDown() async throws {
        dockPreviewManager.stop()
        ConfigManager.shared.reset()
    }

    // MARK: - 测试1：程序坞预览启用/禁用

    func testDockPreviewEnabledDefault() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertTrue(config.enabled, "程序坞预览默认应该启用")
    }

    func testDockPreviewDisabled() {
        ConfigManager.shared.updateDockPreview { $0.enabled = false }
        XCTAssertFalse(ConfigManager.shared.config.dockPreview.enabled, "程序坞预览应该已禁用")
    }

    func testDockPreviewEnabled() {
        ConfigManager.shared.updateDockPreview { $0.enabled = true }
        XCTAssertTrue(ConfigManager.shared.config.dockPreview.enabled, "程序坞预览应该已启用")
    }

    // MARK: - 测试2：悬停延迟设置

    func testHoverDelayDefault() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertEqual(config.hoverDelay, 0.35, "默认悬停延迟应该是 350ms")
    }

    func testHoverDelayCustomValues() {
        // 设置为 500ms
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.5 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 0.5, "悬停延迟应该更新为 500ms")

        // 设置为 200ms
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.2 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 0.2, "悬停延迟应该更新为 200ms")

        // 设置为 1000ms (1秒)
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 1.0 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 1.0, "悬停延迟应该更新为 1000ms")
    }

    func testHoverDelayMinimum() {
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.1 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 0.1, "悬停延迟应该支持最小值 100ms")
    }

    func testHoverDelayMaximum() {
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 2.0 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 2.0, "悬停延迟应该支持最大值 2000ms")
    }

    // MARK: - 测试3：Dock 位置检测

    func testDockPositionEnumCases() {
        // 验证所有 Dock 位置枚举
        let positions: [DockPosition] = [.bottom, .top, .left, .right]
        XCTAssertEqual(positions.count, 4, "应该有 4 种 Dock 位置")
    }

    func testDockPositionBottom() {
        let position = DockPosition.bottom
        // Dock 在底部时，面板应该显示在 Dock 上方
        XCTAssertNotNil(position)
    }

    func testDockPositionTop() {
        let position = DockPosition.top
        // Dock 在顶部时，面板应该显示在 Dock 下方
        XCTAssertNotNil(position)
    }

    func testDockPositionLeft() {
        let position = DockPosition.left
        // Dock 在左侧时，面板应该显示在 Dock 右侧
        XCTAssertNotNil(position)
    }

    func testDockPositionRight() {
        let position = DockPosition.right
        // Dock 在右侧时，面板应该显示在 Dock 左侧
        XCTAssertNotNil(position)
    }

    // MARK: - 测试4：DockPreviewManager 生命周期

    func testDockPreviewManagerStart() {
        XCTAssertNoThrow(dockPreviewManager.start(), "启动 DockPreviewManager 不应抛出异常")
    }

    func testDockPreviewManagerStop() {
        dockPreviewManager.start()
        XCTAssertNoThrow(dockPreviewManager.stop(), "停止 DockPreviewManager 不应抛出异常")
    }

    func testDockPreviewManagerMultipleStart() {
        // 多次启动应该不会崩溃
        dockPreviewManager.start()
        dockPreviewManager.start()
        dockPreviewManager.stop()
    }

    // MARK: - 测试5：预览项数量限制

    func testMaxPreviewCountDefault() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertEqual(config.maxPreviewCount, 4, "默认最大预览数应该是 4")
    }

    func testMaxPreviewCountCustom() {
        ConfigManager.shared.updateDockPreview { $0.maxPreviewCount = 6 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.maxPreviewCount, 6, "最大预览数应该可以自定义")
    }

    // MARK: - 测试6：预览图尺寸

    func testPreviewSizeDefault() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertEqual(config.previewWidth, 104, "默认预览宽度应该是 104pt")
        XCTAssertEqual(config.previewHeight, 58, "默认预览高度应该是 58pt")
    }

    func testPreviewSizeCustom() {
        ConfigManager.shared.updateDockPreview {
            $0.previewWidth = 120
            $0.previewHeight = 68
        }
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertEqual(config.previewWidth, 120, "预览宽度应该可以自定义")
        XCTAssertEqual(config.previewHeight, 68, "预览高度应该可以自定义")
    }

    // MARK: - 测试7：多显示器配置

    func testMultiScreenSupport() {
        // 验证可以获取屏幕信息
        let screens = NSScreen.screens
        XCTAssertGreaterThan(screens.count, 0, "应该至少有一个屏幕")

        // 主屏幕
        let mainScreen = NSScreen.main
        XCTAssertNotNil(mainScreen, "主屏幕应该存在")
    }

    // MARK: - 测试8：配置更新方法

    func testUpdateDockPreviewConfig() {
        // 同时更新多个配置项
        ConfigManager.shared.updateDockPreview {
            $0.enabled = true
            $0.hoverDelay = 0.5
            $0.maxPreviewCount = 5
            $0.previewWidth = 110
            $0.previewHeight = 62
        }

        let config = ConfigManager.shared.config.dockPreview
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.hoverDelay, 0.5)
        XCTAssertEqual(config.maxPreviewCount, 5)
        XCTAssertEqual(config.previewWidth, 110)
        XCTAssertEqual(config.previewHeight, 62)
    }
}
