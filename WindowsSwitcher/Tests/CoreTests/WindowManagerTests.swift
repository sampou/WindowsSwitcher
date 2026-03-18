import XCTest
@testable import WindowsSwitcher

// MARK: - T-019 窗口管理器单元测试
final class WindowManagerTests: XCTestCase {

    // MARK: - FilterEngine 测试（可在无权限环境运行）

    func testFilterBySearchText() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let criteria = FilterCriteria(searchText: "Safari", showMinimized: true, showHidden: true)
        let result = engine.filter(windows, by: criteria)
        XCTAssertTrue(result.allSatisfy { $0.appName.contains("Safari") || $0.windowTitle.contains("Safari") })
    }

    func testFilterExcludesMinimized() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let criteria = FilterCriteria(searchText: "", showMinimized: false, showHidden: true)
        let result = engine.filter(windows, by: criteria)
        XCTAssertFalse(result.contains { $0.isMinimized })
    }

    func testFilterExcludesHidden() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        let criteria = FilterCriteria(searchText: "", showMinimized: true, showHidden: false)
        let result = engine.filter(windows, by: criteria)
        XCTAssertFalse(result.contains { $0.isHidden })
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

    func testEmptyWindowList() {
        let engine = FilterEngine()
        let result = engine.filter([], by: FilterCriteria(searchText: "test", showMinimized: true, showHidden: true))
        XCTAssertTrue(result.isEmpty)
    }

    func testFuzzySearch() {
        let engine = FilterEngine()
        let windows = makeMockWindows()
        // 小写模糊匹配
        let criteria = FilterCriteria(searchText: "saf", showMinimized: true, showHidden: true)
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
