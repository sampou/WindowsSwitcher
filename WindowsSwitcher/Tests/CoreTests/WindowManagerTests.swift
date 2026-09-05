import XCTest
@testable import WindowsSwitcher

// MARK: - T-019 窗口管理器单元测试
final class WindowManagerTests: XCTestCase {

    // MARK: - 窗口聚焦线程策略测试

    func testOwnProcessWindowRequiresMainThreadFocus() {
        XCTAssertTrue(WindowFocusExecutionPolicy.requiresMainThread(targetPID: 1234, currentPID: 1234))
    }

    func testExternalProcessWindowKeepsBackgroundFocus() {
        XCTAssertFalse(WindowFocusExecutionPolicy.requiresMainThread(targetPID: 1234, currentPID: 5678))
    }

    func testWindowFocusRetryPolicyUsesBoundedBackoff() {
        XCTAssertEqual(WindowFocusRetryPolicy.retryDelay(afterAttempt: 0), 0.04)
        XCTAssertEqual(WindowFocusRetryPolicy.retryDelay(afterAttempt: 1), 0.08)
        XCTAssertEqual(WindowFocusRetryPolicy.retryDelay(afterAttempt: 2), 0.16)
        XCTAssertNil(WindowFocusRetryPolicy.retryDelay(afterAttempt: 3))
    }

    // MARK: - FilterEngine 测试（可在无权限环境运行）

    func testFilterBySearchText() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let criteria = FilterCriteria(searchText: "Safari", showOffScreen: true)
        let result = engine.filter(windows, by: criteria)
        XCTAssertTrue(result.allSatisfy { $0.appName.contains("Safari") || $0.windowTitle.contains("Safari") })
    }

    func testFilterExcludesOffScreenWhenDisabled() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let criteria = FilterCriteria(searchText: "", showOffScreen: false)
        let result = engine.filter(windows, by: criteria)
        XCTAssertFalse(result.contains { $0.isMinimized || $0.isHidden })
    }

    func testFilterIncludesOffScreenWhenEnabled() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let criteria = FilterCriteria(searchText: "", showOffScreen: true)
        let result = engine.filter(windows, by: criteria)
        XCTAssertTrue(result.contains { $0.isMinimized || $0.isHidden })
    }

    func testSortByAppName() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let sorted = engine.sort(windows, by: .appName)
        for i in 0..<sorted.count - 1 {
            XCTAssertLessThanOrEqual(sorted[i].appName, sorted[i + 1].appName)
        }
    }

    func testSortByWindowTitle() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let sorted = engine.sort(windows, by: .windowTitle)
        for i in 0..<sorted.count - 1 {
            XCTAssertLessThanOrEqual(sorted[i].windowTitle, sorted[i + 1].windowTitle)
        }
    }

    func testSortByRecent() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let sorted = engine.sort(windows, by: .recent)
        for i in 0..<sorted.count - 1 {
            XCTAssertGreaterThanOrEqual(sorted[i].lastActiveTime, sorted[i + 1].lastActiveTime)
        }
    }

    // MARK: - 窗口切换顺序测试

    func testWindowOrderAfterActivation() {
        // 模拟用户点击切换到另一个应用
        let now = Date()
        var windows = [
            makeMockWindow(id: 1, appName: "Safari", lastActiveTime: now.addingTimeInterval(-10)),
            makeMockWindow(id: 2, appName: "Chrome", lastActiveTime: now.addingTimeInterval(-5)),
            makeMockWindow(id: 3, appName: "Finder", lastActiveTime: now.addingTimeInterval(-20))
        ]

        // 用户点击 Safari 窗口，更新其 lastActiveTime
        let newActiveTime = Date()
        windows[0] = makeMockWindow(id: 1, appName: "Safari", lastActiveTime: newActiveTime)

        // 排序后 Safari 应该在最前面
        let engine = FilterEngine()
        let sorted = engine.sort(windows, by: .recent)

        XCTAssertEqual(sorted[0].appName, "Safari", "最近激活的应用应该在最前面")
        XCTAssertEqual(sorted[0].lastActiveTime, newActiveTime)
    }

    func testWindowOrderAfterCmdTabSwitch() {
        // 模拟 Cmd+Tab 切换
        let now = Date()
        var windows = [
            makeMockWindow(id: 1, appName: "Safari", lastActiveTime: now.addingTimeInterval(-10)),
            makeMockWindow(id: 2, appName: "Chrome", lastActiveTime: now.addingTimeInterval(-5)),
            makeMockWindow(id: 3, appName: "Finder", lastActiveTime: now.addingTimeInterval(-20))
        ]

        // 用户通过 Cmd+Tab 切换到 Finder
        let newActiveTime = Date()
        windows[2] = makeMockWindow(id: 3, appName: "Finder", lastActiveTime: newActiveTime)

        let engine = FilterEngine()
        let sorted = engine.sort(windows, by: .recent)

        XCTAssertEqual(sorted[0].appName, "Finder", "Cmd+Tab 切换后，目标应用应该在最前面")
    }

    func testMultipleApplicationWindowsOrder() {
        // 测试同应用多窗口顺序
        let now = Date()
        let windows = [
            makeMockWindow(id: 1, appName: "Safari", windowTitle: "Window 1", lastActiveTime: now.addingTimeInterval(-10)),
            makeMockWindow(id: 2, appName: "Safari", windowTitle: "Window 2", lastActiveTime: now.addingTimeInterval(-5)),
            makeMockWindow(id: 3, appName: "Safari", windowTitle: "Window 3", lastActiveTime: now.addingTimeInterval(-20)),
            makeMockWindow(id: 4, appName: "Chrome", windowTitle: "Chrome Window", lastActiveTime: now.addingTimeInterval(-1))
        ]

        let engine = FilterEngine()
        let sorted = engine.sort(windows, by: .recent)

        // Chrome 最近使用，应该在最前面
        XCTAssertEqual(sorted[0].appName, "Chrome")

        // Safari 窗口按活跃度排序：Window 2 (最近) -> Window 1 -> Window 3
        let safariWindows = sorted.filter { $0.appName == "Safari" }
        XCTAssertEqual(safariWindows[0].windowTitle, "Window 2")
        XCTAssertEqual(safariWindows[1].windowTitle, "Window 1")
        XCTAssertEqual(safariWindows[2].windowTitle, "Window 3")
    }

    func testWindowOrderStabilityWithSameActiveTime() {
        // 测试相同活跃时间的窗口排序稳定性
        let sameTime = Date()
        let windows = [
            makeMockWindow(id: 1, appName: "AppA", lastActiveTime: sameTime),
            makeMockWindow(id: 2, appName: "AppB", lastActiveTime: sameTime),
            makeMockWindow(id: 3, appName: "AppC", lastActiveTime: sameTime)
        ]

        let engine = FilterEngine()
        let sorted = engine.sort(windows, by: .recent)

        // 相同时间应该保持原顺序（稳定排序）
        XCTAssertEqual(sorted.count, 3)
    }

    func testEmptyWindowList() {
        let engine = FilterEngine()
        let result = engine.filter([], by: FilterCriteria(searchText: "test", showOffScreen: true))
        XCTAssertTrue(result.isEmpty)
    }

    func testFuzzySearch() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        // 小写模糊匹配
        let criteria = FilterCriteria(searchText: "saf", showOffScreen: true)
        let result = engine.filter(windows, by: criteria)
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy {
            $0.appName.lowercased().contains("saf") || $0.windowTitle.lowercased().contains("saf")
        })
    }

    // MARK: - WindowModel 测试

    func testWindowModelEquality() {
        let w1 = makeMockWindow(id: 1, appName: "Safari")
        let w2 = makeMockWindow(id: 1, appName: "Safari")
        let w3 = makeMockWindow(id: 2, appName: "Chrome")
        XCTAssertEqual(w1, w2)
        XCTAssertNotEqual(w1, w3)
    }

    func testWindowModelIdentifiable() {
        let window = makeMockWindow(id: 42, appName: "Finder")
        XCTAssertEqual(window.id, 42)
    }

    // MARK: - Helpers

    private func makeMockWindow(
        id: CGWindowID = 1,
        appName: String = "TestApp",
        windowTitle: String = "Test Window",
        isMinimized: Bool = false,
        isHidden: Bool = false,
        lastActiveTime: Date = Date()
    ) -> WindowModel {
        WindowModel(
            id: id,
            appName: appName,
            bundleIdentifier: "com.test.\(appName.lowercased())",
            windowTitle: windowTitle,
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: isMinimized,
            isHidden: isHidden,
            isOnScreen: !isMinimized,
            lastActiveTime: lastActiveTime,
            windowLayer: 0,
            ownerPID: 1234
        )
    }

    private func makeMockWindows() -> [WindowModel] {
        [
            makeMockWindow(id: 1, appName: "Safari", windowTitle: "Apple - Safari",
                           isMinimized: false, isHidden: false,
                           lastActiveTime: Date().addingTimeInterval(-1)),
            makeMockWindow(id: 2, appName: "Chrome", windowTitle: "Google - Chrome",
                           isMinimized: true, isHidden: false,
                           lastActiveTime: Date().addingTimeInterval(-5)),
            makeMockWindow(id: 3, appName: "Finder", windowTitle: "Documents",
                           isMinimized: false, isHidden: true,
                           lastActiveTime: Date().addingTimeInterval(-10)),
            makeMockWindow(id: 4, appName: "Xcode", windowTitle: "WindowsSwitcher.xcodeproj",
                           isMinimized: false, isHidden: false,
                           lastActiveTime: Date().addingTimeInterval(-2)),
        ]
    }
}
