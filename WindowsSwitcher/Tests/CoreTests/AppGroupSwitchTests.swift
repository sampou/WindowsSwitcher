import XCTest
@testable import WindowsSwitcher

// MARK: - 应用分组切换测试
// 测试 SwitchPanelViewModel 的窗口重排逻辑和性能

@MainActor
final class AppGroupSwitchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConfigManager.shared.reset()
    }

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
    }

    // MARK: - 测试数据

    /// 创建测试用窗口模型
    private func makeWindow(
        id: CGWindowID,
        app: String,
        bundleID: String,
        activeTime: Date,
        title: String? = nil
    ) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: bundleID,
            windowTitle: title ?? "\(app) Window \(id)",
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: activeTime,
            windowLayer: 0,
            ownerPID: pid_t(id * 100)
        )
    }

    // MARK: - 测试 1: SortOrder 现有选项正常工作

    func testSortOrderOptionsExist() {
        // 验证现有 SortOrder 选项
        let sortOrders = SortOrder.allCases
        XCTAssertTrue(sortOrders.contains(.recent), "SortOrder 应包含 .recent")
        XCTAssertTrue(sortOrders.contains(.appName), "SortOrder 应包含 .appName")
        XCTAssertTrue(sortOrders.contains(.windowTitle), "SortOrder 应包含 .windowTitle")
        XCTAssertTrue(sortOrders.contains(.appGroup), "SortOrder 应包含 .appGroup")
    }

    func testSortOrderCanBeConfigured() {
        // 验证可以通过 ConfigManager 设置
        ConfigManager.shared.updateBehavior { $0.sortOrder = .recent }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .recent)

        ConfigManager.shared.updateBehavior { $0.sortOrder = .appName }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .appName)

        ConfigManager.shared.updateBehavior { $0.sortOrder = .windowTitle }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .windowTitle)

        // 验证应用分组排序选项
        ConfigManager.shared.updateBehavior { $0.sortOrder = .appGroup }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .appGroup)
    }

    // MARK: - 测试 1.1: 应用分组排序配置测试

    func testAppGroupSortOrderConfiguration() {
        // 测试通过配置启用应用分组排序
        ConfigManager.shared.updateBehavior { $0.sortOrder = .appGroup }

        let behavior = ConfigManager.shared.config.behavior
        XCTAssertEqual(behavior.sortOrder, .appGroup, "应用分组排序应该能正确保存")

        // 验证 SortOrder.appGroup 枚举值正确
        XCTAssertEqual(SortOrder.appGroup.rawValue, "appGroup", "appGroup 枚举值应该是 'appGroup'")
    }

    // MARK: - 测试 2: 按活跃度排序 (recent)

    func testSortByRecentActivity() {
        let now = Date()
        let windows = [
            makeWindow(id: 1, app: "AppA", bundleID: "com.appA", activeTime: now.addingTimeInterval(-10)),
            makeWindow(id: 2, app: "AppB", bundleID: "com.appB", activeTime: now.addingTimeInterval(-5)),
            makeWindow(id: 3, app: "AppC", bundleID: "com.appC", activeTime: now.addingTimeInterval(-20))
        ]

        let filterEngine = FilterEngine()
        let sorted = filterEngine.sort(windows, by: .recent)

        // 验证按活跃度降序（最近的在前）
        XCTAssertEqual(sorted[0].id, 2, "最近活跃的窗口应该在最前面")
        XCTAssertEqual(sorted[1].id, 1)
        XCTAssertEqual(sorted[2].id, 3)
    }

    // MARK: - 测试 3: 按应用名称排序

    func testSortByAppName() {
        let now = Date()
        let windows = [
            makeWindow(id: 1, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: now),
            makeWindow(id: 3, app: "Xcode", bundleID: "com.apple.dt.Xcode", activeTime: now)
        ]

        let filterEngine = FilterEngine()
        let sorted = filterEngine.sort(windows, by: .appName)

        // 验证按应用名称字母顺序排序
        XCTAssertEqual(sorted[0].appName, "Chrome")
        XCTAssertEqual(sorted[1].appName, "Safari")
        XCTAssertEqual(sorted[2].appName, "Xcode")
    }

    // MARK: - 测试 4: 按窗口标题排序

    func testSortByWindowTitle() {
        let now = Date()
        // 直接创建不同标题的窗口
        let windows = [
            makeWindow(id: 1, app: "App", bundleID: "com.app", activeTime: now, title: "Window B"),
            makeWindow(id: 2, app: "App", bundleID: "com.app", activeTime: now, title: "Window A"),
            makeWindow(id: 3, app: "App", bundleID: "com.app", activeTime: now, title: "Window C")
        ]

        let filterEngine = FilterEngine()
        let sorted = filterEngine.sort(windows, by: .windowTitle)

        // 验证按窗口标题字母顺序排序
        XCTAssertEqual(sorted[0].windowTitle, "Window A")
        XCTAssertEqual(sorted[1].windowTitle, "Window B")
        XCTAssertEqual(sorted[2].windowTitle, "Window C")
    }

    // MARK: - 测试 5: FilterEngine 多应用混合排序

    func testFilterEngineSortMultipleApps() {
        let now = Date()
        let windows = [
            makeWindow(id: 1, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-5)),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-2)),
            makeWindow(id: 3, app: "Xcode", bundleID: "com.apple.dt.Xcode", activeTime: now.addingTimeInterval(-10)),
            makeWindow(id: 4, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-8))
        ]

        let filterEngine = FilterEngine()
        let sorted = filterEngine.sort(windows, by: .recent)

        // 验证排序正确
        XCTAssertEqual(sorted[0].bundleIdentifier, "com.apple.Safari", "最近活跃的 Safari 应该在最前面")
    }

    // MARK: - 测试 5.1: 应用分组排序 (.appGroup)

    func testSortByAppGroup() {
        let now = Date()
        let windows = [
            makeWindow(id: 1, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-5)),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-2)),
            makeWindow(id: 3, app: "Xcode", bundleID: "com.apple.dt.Xcode", activeTime: now.addingTimeInterval(-10)),
            makeWindow(id: 4, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-8)),
            makeWindow(id: 5, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-1))
        ]

        let filterEngine = FilterEngine()
        let sorted = filterEngine.sort(windows, by: .appGroup)

        // 验证按应用分组（最近活跃应用在前）
        XCTAssertEqual(sorted[0].bundleIdentifier, "com.apple.Safari", "最近活跃的 Safari 应该在最前面")
        // Safari 有两个窗口
        XCTAssertEqual(sorted[1].bundleIdentifier, "com.apple.Safari")
        // 然后是 Chrome
        XCTAssertEqual(sorted[2].bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(sorted[3].bundleIdentifier, "com.google.Chrome")
        // 最后是 Xcode
        XCTAssertEqual(sorted[4].bundleIdentifier, "com.apple.dt.Xcode")
    }

    // MARK: - 测试 6: 切换操作响应时间（性能测试）

    func testSwitchOperationPerformance() {
        // 创建较大数量的窗口进行性能测试
        let now = Date()
        let apps = ["AppA", "AppB", "AppC", "AppD", "AppE"]
        var windows: [WindowModel] = []

        for i in 0..<50 {
            let appIndex = i % apps.count
            let window = makeWindow(
                id: CGWindowID(i + 1),
                app: apps[appIndex],
                bundleID: "com.\(apps[appIndex].lowercased())",
                activeTime: now.addingTimeInterval(-Double(i))
            )
            windows.append(window)
        }

        windows.sort { $0.lastActiveTime > $1.lastActiveTime }

        let mockManager = TestWindowManager(windows: windows)
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        // 测量切换操作耗时
        let startTime = CFAbsoluteTimeGetCurrent()

        for _ in 0..<100 {
            vm.selectNext()
            vm.selectPrevious()
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime

        // 100 次切换操作应该在 1 秒内完成
        XCTAssertLessThan(duration, 1.0,
            "100 次切换操作应在 1 秒内完成，实际耗时: \(duration)s")
    }

    // MARK: - 测试 7: 切换稳定性测试

    func testSwitchOperationStability() {
        let now = Date()
        var windows = [
            makeWindow(id: 1, app: "AppA", bundleID: "com.appA", activeTime: now.addingTimeInterval(-1)),
            makeWindow(id: 2, app: "AppA", bundleID: "com.appA", activeTime: now.addingTimeInterval(-2)),
            makeWindow(id: 3, app: "AppB", bundleID: "com.appB", activeTime: now.addingTimeInterval(-3))
        ]

        windows.sort { $0.lastActiveTime > $1.lastActiveTime }

        let mockManager = TestWindowManager(windows: windows)
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        // 连续切换不应崩溃
        for _ in 0..<50 {
            vm.selectNext()
            vm.selectPrevious()
        }

        // 验证切换后索引有效
        XCTAssertTrue(vm.selectedIndex >= 0, "选中索引应有效")
        XCTAssertTrue(vm.selectedIndex < vm.filteredWindows.count, "选中索引应在范围内")
    }

    // MARK: - 测试 8: 大量窗口切换稳定性

    func testSwitchWithLargeWindowCount() {
        let now = Date()
        var windows: [WindowModel] = []

        // 创建 100 个窗口
        for i in 0..<100 {
            let window = makeWindow(
                id: CGWindowID(i + 1),
                app: "App\(i % 10)",
                bundleID: "com.app\(i % 10)",
                activeTime: now.addingTimeInterval(-Double(i))
            )
            windows.append(window)
        }

        windows.sort { $0.lastActiveTime > $1.lastActiveTime }

        let mockManager = TestWindowManager(windows: windows)
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        // 执行 200 次切换
        for i in 0..<200 {
            if i % 2 == 0 {
                vm.selectNext()
            } else {
                vm.selectPrevious()
            }
        }

        // 验证状态仍然有效
        XCTAssertEqual(vm.filteredWindows.count, 100)
        XCTAssertTrue(vm.selectedIndex >= 0)
    }
}

// MARK: - Test WindowManager

private class TestWindowManager: WindowManagerProtocol {
    var testWindows: [WindowModel]
    var activateCallCount = 0

    init(windows: [WindowModel]) {
        self.testWindows = windows
    }

    nonisolated func getAllWindows(forceRefresh: Bool = false) -> [WindowModel] {
        return testWindows
    }

    nonisolated func getWindows(for appName: String) -> [WindowModel] {
        return testWindows.filter { $0.appName == appName }
    }

    nonisolated func activateWindow(_ window: WindowModel) {
        activateCallCount += 1
    }

    nonisolated func closeWindow(_ window: WindowModel) {}
    nonisolated func minimizeWindow(_ window: WindowModel) {}
    nonisolated func hideWindow(_ window: WindowModel) {}
    nonisolated func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {}
    nonisolated func refreshCache() {}
    nonisolated func startMonitoring() {}
    nonisolated func stopMonitoring() {}
}
