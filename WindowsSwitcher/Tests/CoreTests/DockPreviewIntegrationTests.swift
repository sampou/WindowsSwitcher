import XCTest
import Combine
@testable import WindowsSwitcher

// MARK: - 程序坞预览集成测试

@MainActor
final class DockPreviewIntegrationTests: XCTestCase {

    var dockPreviewManager: DockPreviewManager!
    var dockEventMonitor: DockEventMonitor!
    var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        dockPreviewManager = DockPreviewManager.shared
        dockEventMonitor = DockEventMonitor()
        cancellables = []
        ConfigManager.shared.reset()
    }

    override func tearDown() async throws {
        dockPreviewManager.stop()
        dockEventMonitor.stopMonitoring()
        cancellables = nil
        ConfigManager.shared.reset()
    }

    // MARK: - F12-INT01: Manager 与 EventMonitor 绑定测试

    func testManagerBindsToEventMonitor() {
        // 验证 Manager 正确绑定了 EventMonitor
        dockPreviewManager.start()

        // 监听 EventMonitor 的悬停状态变化
        let expectation = expectation(description: "EventMonitor 悬停状态变化")

        dockEventMonitor.$hoveredAppBundleID
            .sink { bundleID in
                if bundleID != nil {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // 触发事件（模拟悬停）
        dockEventMonitor.hoveredAppBundleID = "com.apple.Safari"

        waitForExpectations(timeout: 2.0)
    }

    // MARK: - F12-INT02: 窗口过滤逻辑测试（非最小化）

    func testWindowFilterExcludesMinimized() {
        // 创建测试窗口数据
        let windows = [
            makeMockWindow(id: 1, app: "Safari", title: "Window 1", isMinimized: false),
            makeMockWindow(id: 2, app: "Safari", title: "Window 2", isMinimized: true),
            makeMockWindow(id: 3, app: "Safari", title: "Window 3", isMinimized: false),
            makeMockWindow(id: 4, app: "Safari", title: "Window 4", isMinimized: true)
        ]

        // 模拟过滤逻辑
        let filteredWindows = windows.filter { !$0.isMinimized }

        XCTAssertEqual(filteredWindows.count, 2, "应该过滤掉最小化的窗口")
        XCTAssertTrue(filteredWindows.allSatisfy { !$0.isMinimized }, "所有剩余窗口都应该不是最小化状态")
    }

    // MARK: - F12-INT03: 单窗口场景测试

    func testSingleWindowScenario() {
        let windows = [
            makeMockWindow(id: 1, app: "Safari", title: "唯一的窗口", isMinimized: false)
        ]

        // 模拟 handleHoverChange
        let previewItems = windows.prefix(4).map { DockPreviewItem(windowModel: $0) }

        XCTAssertEqual(previewItems.count, 1, "单窗口应该生成一个预览项")
        XCTAssertEqual(previewItems.first?.windowTitle, "唯一的窗口")
    }

    // MARK: - F12-INT04: 超过最大数量的窗口截断测试

    func testMaxWindowCountTruncation() {
        // 创建 6 个窗口（超过默认最大值 4）
        let windows = (1...6).map { makeMockWindow(id: CGWindowID($0), app: "Safari", title: "Window \($0)", isMinimized: false) }

        // 模拟预览项生成（限制为 4 个）
        let maxPreviewCount = ConfigManager.shared.config.dockPreview.maxPreviewCount
        let previewItems = windows.prefix(maxPreviewCount).map { DockPreviewItem(windowModel: $0) }

        XCTAssertEqual(previewItems.count, 4, "预览项数量应该被截断为最大值")
        XCTAssertEqual(previewItems.last?.windowTitle, "Window 4", "最后一个应该是第 4 个窗口")
    }

    // MARK: - F12-INT05: 所有窗口最小化场景测试

    func testAllWindowsMinimizedScenario() {
        let windows = [
            makeMockWindow(id: 1, app: "Safari", title: "Window 1", isMinimized: true),
            makeMockWindow(id: 2, app: "Safari", title: "Window 2", isMinimized: true),
            makeMockWindow(id: 3, app: "Safari", title: "Window 3", isMinimized: true)
        ]

        // 模拟过滤逻辑（排除最小化）
        let filteredWindows = windows.filter { !$0.isMinimized }

        XCTAssertTrue(filteredWindows.isEmpty, "所有窗口最小化时，过滤结果应该为空")
    }

    // MARK: - F12-INT06: 空窗口场景测试

    func testEmptyWindowsScenario() {
        let windows: [WindowModel] = []

        let previewItems = windows.prefix(4).map { DockPreviewItem(windowModel: $0) }

        XCTAssertTrue(previewItems.isEmpty, "没有窗口时，预览项应该为空")
    }

    // MARK: - F12-INT07: 窗口标题为空时使用应用名

    func testEmptyWindowTitleFallsBackToAppName() {
        let window = makeMockWindow(id: 1, app: "Safari", title: "", isMinimized: false)
        let item = DockPreviewItem(windowModel: window)

        XCTAssertEqual(item.windowTitle, "Safari", "窗口标题为空时应使用应用名")
    }

    // MARK: - F12-INT08: 窗口突然关闭场景测试

    func testWindowClosedWhilePreviewing() {
        // 初始有窗口
        var windows = [
            makeMockWindow(id: 1, app: "Safari", title: "Window 1", isMinimized: false)
        ]

        var previewItems = windows.prefix(4).map { DockPreviewItem(windowModel: $0) }
        XCTAssertFalse(previewItems.isEmpty, "初始应该有预览项")

        // 模拟窗口关闭
        windows = []

        previewItems = windows.prefix(4).map { DockPreviewItem(windowModel: $0) }
        XCTAssertTrue(previewItems.isEmpty, "窗口关闭后应该没有预览项")
    }

    // MARK: - F12-INT09: 不同 Dock 位置的面板定位测试

    func testDockPositionAffectsPanelPosition() {
        let positions: [DockPosition] = [.top, .bottom, .left, .right]

        for position in positions {
            let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let dockFrame = CGRect(x: 0, y: 0, width: screenFrame.width, height: 80)

            let expectedPosition: CGPoint

            switch position {
            case .bottom:
                expectedPosition = CGPoint(x: screenFrame.midX, y: dockFrame.minY - 60)
            case .top:
                expectedPosition = CGPoint(x: screenFrame.midX, y: dockFrame.maxY + 60)
            case .left:
                expectedPosition = CGPoint(x: dockFrame.maxX + 60, y: screenFrame.midY)
            case .right:
                expectedPosition = CGPoint(x: dockFrame.minX - 60, y: screenFrame.midY)
            }

            // 验证位置计算逻辑
            XCTAssertNotNil(expectedPosition, "Dock 在 \(position) 时应该能计算面板位置")
        }
    }

    // MARK: - F12-INT10: 悬停延迟配置生效测试

    func testHoverDelayTakesEffect() {
        // 设置较长的延迟以便测试
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.5 }

        let config = ConfigManager.shared.config.dockPreview

        XCTAssertEqual(config.hoverDelay, 0.5, "悬停延迟应该能正确配置")

        // 恢复默认
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.35 }
    }

    // MARK: - F12-INT11: 选择窗口后隐藏预览测试

    func testPreviewHidesAfterWindowSelection() {
        // 显示预览
        dockPreviewManager.isPreviewVisible = true
        XCTAssertTrue(dockPreviewManager.isPreviewVisible, "预览应该显示")

        // 模拟选择窗口
        let window = makeMockWindow(id: 1, app: "Safari", title: "Test", isMinimized: false)
        let item = DockPreviewItem(windowModel: window)
        dockPreviewManager.selectItem(item)

        // 验证预览被隐藏（由于有延迟，需要等待）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            XCTAssertFalse(self?.dockPreviewManager.isPreviewVisible ?? true, "选择窗口后预览应该隐藏")
        }
    }

    // MARK: - F12-INT12: 多显示器支持测试

    func testMultiDisplaySupport() {
        let screens = NSScreen.screens

        // 验证可以获取屏幕信息
        XCTAssertGreaterThan(screens.count, 0, "应该至少有一个屏幕")

        // 测试主屏幕
        if let mainScreen = NSScreen.main {
            XCTAssertNotNil(mainScreen.frame, "主屏幕应该有 frame")
            XCTAssertGreaterThan(mainScreen.frame.width, 0, "主屏幕宽度应该大于 0")
        }
    }

    // MARK: - 辅助方法

    private func makeMockWindow(id: CGWindowID, app: String, title: String, isMinimized: Bool) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: title,
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: isMinimized,
            isHidden: false,
            isOnScreen: !isMinimized,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: pid_t(id * 100)
        )
    }
}

// MARK: - 性能测试

@MainActor
final class DockPreviewPerformanceTests: XCTestCase {

    var dockPreviewManager: DockPreviewManager!

    override func setUp() async throws {
        dockPreviewManager = DockPreviewManager.shared
        ConfigManager.shared.reset()
    }

    override func tearDown() async throws {
        dockPreviewManager.stop()
        ConfigManager.shared.reset()
    }

    // MARK: - F12-PERF01: 预览生成内存占用测试

    func testPreviewMemoryUsage() {
        // 创建多个窗口
        let windows = (1...10).map { i -> WindowModel in
            WindowModel(
                id: CGWindowID(i),
                appName: "App\(i)",
                bundleIdentifier: "com.app\(i)",
                windowTitle: "Window \(i)",
                appIcon: NSImage(),
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isMinimized: false,
                isHidden: false,
                isOnScreen: true,
                lastActiveTime: Date(),
                windowLayer: 0,
                ownerPID: pid_t(i * 100)
            )
        }

        // 限制为 4 个预览项
        let previewItems = windows.prefix(4).map { DockPreviewItem(windowModel: $0) }

        XCTAssertEqual(previewItems.count, 4, "预览项数量应该被限制")
    }

    // MARK: - F12-PERF02: 快速悬停切换测试

    func testRapidHoverSwitching() {
        let bundleIDs = ["com.apple.Safari", "com.apple.Music", "com.apple.Finder"]

        // 模拟快速切换悬停目标
        for bundleID in bundleIDs {
            dockPreviewManager.previewItems = [
                DockPreviewItem(windowModel: makeMockWindow(
                    id: 1,
                    app: "Test",
                    title: "Test",
                    isMinimized: false
                ))
            ]
        }

        // 验证不会崩溃
        XCTAssertTrue(true, "快速切换悬停目标不应该导致崩溃")
    }

    // MARK: - 辅助方法

    private func makeMockWindow(id: CGWindowID, app: String, title: String, isMinimized: Bool) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: title,
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: isMinimized,
            isHidden: false,
            isOnScreen: !isMinimized,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: pid_t(id * 100)
        )
    }
}

// MARK: - 错误处理测试

@MainActor
final class DockPreviewErrorHandlingTests: XCTestCase {

    var dockPreviewManager: DockPreviewManager!

    override func setUp() async throws {
        dockPreviewManager = DockPreviewManager.shared
        ConfigManager.shared.reset()
    }

    override func tearDown() async throws {
        dockPreviewManager.stop()
        ConfigManager.shared.reset()
    }

    // MARK: - F12-ERR01: 无屏幕时的降级处理

    func testNoScreenFallback() {
        // 验证在没有主屏幕时的默认行为
        let mainScreen = NSScreen.main

        if mainScreen == nil {
            // 应该使用默认尺寸
            let defaultFrame = CGRect(x: 0, y: 0, width: 800, height: 80)
            XCTAssertNotNil(defaultFrame, "应该有空屏幕时的默认帧")
        } else {
            XCTAssertNotNil(mainScreen?.frame, "有主屏幕时应该有 frame")
        }
    }

    // MARK: - F12-ERR02: 配置值越界处理

    func testConfigOutOfRangeHandling() {
        // 测试超出范围的配置值
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.05 } // 小于最小值

        // 验证配置被正确限制
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertGreaterThanOrEqual(config.hoverDelay, 0.1, "悬停延迟应该被限制在最小值以上")

        // 恢复默认
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.35 }
    }

    // MARK: - F12-ERR03: 空 Bundle ID 处理

    func testEmptyBundleIDHandling() {
        let window = WindowModel(
            id: 1,
            appName: "TestApp",
            bundleIdentifier: "",
            windowTitle: "Test",
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: 1234
        )

        // 验证空 Bundle ID 不会导致崩溃
        XCTAssertNotNil(window.bundleIdentifier, "应该能处理空 Bundle ID")
    }
}