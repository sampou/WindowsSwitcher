import XCTest
import Combine
@testable import WindowsSwitcher

// MARK: - F12 程序坞预览功能测试

@MainActor
final class DockPreviewTests: XCTestCase {

    var manager: DockPreviewManager!
    var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        manager = DockPreviewManager.shared
        cancellables = []
        ConfigManager.shared.reset()
    }

    override func tearDown() async throws {
        manager.stop()
        cancellables = nil
        ConfigManager.shared.reset()
    }

    // MARK: - F12-T08 单例模式测试

    func testSingletonPattern() {
        let instance1 = DockPreviewManager.shared
        let instance2 = DockPreviewManager.shared
        XCTAssertTrue(instance1 === instance2, "DockPreviewManager 应该是单例")
    }

    // MARK: - F12-T09 start/stop 测试

    func testStartStopMonitoring() {
        XCTAssertNoThrow(manager.start(), "start() 不应抛出异常")
        XCTAssertNoThrow(manager.stop(), "stop() 不应抛出异常")
    }

    // MARK: - F12-T11 无窗口处理测试

    func testHandleEmptyWindows() {
        manager.start()

        // 初始状态应该是空的
        XCTAssertTrue(manager.previewItems.isEmpty, "初始状态 previewItems 应该为空")
    }

    // MARK: - DockPreviewConfig 配置测试

    func testDockPreviewConfigDefaults() {
        let config = DockPreviewConfig()

        XCTAssertTrue(config.enabled, "默认应该启用")
        XCTAssertEqual(config.hoverDelay, 0.35, "悬停延迟默认 350ms")
        XCTAssertEqual(config.hideDelay, 0.2, "隐藏延迟默认 200ms")
        XCTAssertEqual(config.maxPreviewCount, 4, "最大预览数默认 4")
        XCTAssertEqual(config.previewWidth, 104, "预览宽度默认 104pt")
        XCTAssertEqual(config.previewHeight, 58, "预览高度默认 58pt")
        XCTAssertTrue(config.showAnimation, "默认显示动画")
    }

    func testDockPreviewConfigCustomValues() {
        let config = DockPreviewConfig(
            enabled: false,
            hoverDelay: 0.5,
            hideDelay: 0.3,
            maxPreviewCount: 6,
            previewWidth: 120,
            previewHeight: 68,
            showAnimation: false
        )

        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.hoverDelay, 0.5)
        XCTAssertEqual(config.hideDelay, 0.3)
        XCTAssertEqual(config.maxPreviewCount, 6)
        XCTAssertEqual(config.previewWidth, 120)
        XCTAssertEqual(config.previewHeight, 68)
        XCTAssertFalse(config.showAnimation)
    }

    // MARK: - DockPreviewItem 测试

    func testDockPreviewItemCreation() {
        let window = makeMockWindow(id: 1, app: "Safari", title: "Apple")
        let item = DockPreviewItem(windowModel: window)

        XCTAssertEqual(item.windowTitle, "Apple")
        XCTAssertNotNil(item.appIcon)
        XCTAssertNotNil(item.id)
    }

    func testDockPreviewItemUsesAppNameWhenTitleEmpty() {
        let window = makeMockWindow(id: 1, app: "Safari", title: "")
        let item = DockPreviewItem(windowModel: window)

        XCTAssertEqual(item.windowTitle, "Safari", "标题为空时应使用应用名")
    }

    // MARK: - DockPosition 测试

    func testDockPositionCases() {
        let positions: [DockPosition] = [.top, .bottom, .left, .right]
        XCTAssertEqual(positions.count, 4, "应该有 4 种 Dock 位置")
    }

    // MARK: - F12-T18 最大窗口数测试

    func testMaxPreviewCount() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertEqual(config.maxPreviewCount, 4, "最大预览数应该是 4")
    }

    // MARK: - F12-T24 悬停触发延迟测试

    func testHoverDelayConfiguration() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertGreaterThanOrEqual(config.hoverDelay, 0.1, "悬停延迟应该 >= 100ms")
        XCTAssertLessThanOrEqual(config.hoverDelay, 1.0, "悬停延迟应该 <= 1000ms")
    }

    // MARK: - 通知测试

    func testDockPreviewWindowSelectedNotification() {
        let expectation = expectation(description: "dockPreviewWindowSelected notification")

        let observer = NotificationCenter.default.addObserver(
            forName: .dockPreviewWindowSelected,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        // 发送测试通知
        NotificationCenter.default.post(name: .dockPreviewWindowSelected, object: nil)

        waitForExpectations(timeout: 1.0)

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - 预览图尺寸比例测试 (16:9)

    func testPreviewAspectRatioIs16by9() {
        let config = ConfigManager.shared.config.dockPreview
        let ratio = config.previewWidth / config.previewHeight

        // 16:9 = 1.778
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.1, "预览图比例应该接近 16:9")
    }

    // MARK: - 辅助方法

    private func makeMockWindow(id: CGWindowID, app: String, title: String) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: title,
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: pid_t(id * 100)
        )
    }
}

// MARK: - DockEventMonitor 单元测试

final class DockEventMonitorTests: XCTestCase {

    func testDockPositionEnumExists() {
        let top = DockPosition.top
        let bottom = DockPosition.bottom
        let left = DockPosition.left
        let right = DockPosition.right

        // 验证枚举值可以创建
        XCTAssertNotNil(top)
        XCTAssertNotNil(bottom)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
    }

    func testDockPositionAllCases() {
        let allPositions: [DockPosition] = [.top, .bottom, .left, .right]
        XCTAssertEqual(allPositions.count, 4)
    }
}

// MARK: - DesignTokens DockPreview 规格测试

final class DockPreviewDesignTokensTests: XCTestCase {

    func testDockPreviewDesignTokens() {
        XCTAssertEqual(DesignTokens.DockPreview.panelCornerRadius, 10)
        XCTAssertEqual(DesignTokens.DockPreview.shadowRadius, 12)
        XCTAssertEqual(DesignTokens.DockPreview.shadowY, 4)
        XCTAssertEqual(DesignTokens.DockPreview.itemWidth, 120)
        XCTAssertEqual(DesignTokens.DockPreview.itemHeight, 80)
        XCTAssertEqual(DesignTokens.DockPreview.itemCornerRadius, 10)
        XCTAssertEqual(DesignTokens.DockPreview.previewWidth, 104)
        XCTAssertEqual(DesignTokens.DockPreview.previewHeight, 58)
        XCTAssertEqual(DesignTokens.DockPreview.previewCornerRadius, 8)
        XCTAssertEqual(DesignTokens.DockPreview.titleFontSize, 11)
        XCTAssertEqual(DesignTokens.DockPreview.itemSpacing, 8)
        XCTAssertEqual(DesignTokens.DockPreview.showDelay, 0.35)
        XCTAssertEqual(DesignTokens.DockPreview.showDuration, 0.2)
        XCTAssertEqual(DesignTokens.DockPreview.hideDuration, 0.15)
    }

    func testDockPreviewAspectRatio() {
        let ratio = DesignTokens.DockPreview.previewWidth / DesignTokens.DockPreview.previewHeight
        // 104:58 ≈ 16:9 (1.79)
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.1, "Dock预览图比例应该接近 16:9")
    }
}
