import XCTest
@testable import WindowsSwitcher

// MARK: - T-040 筛选模块测试 / T-050 功能测试

final class FilterEngineAdvancedTests: XCTestCase {

    let engine = FilterEngine()

    // T-033: 精确应用名筛选
    func testExactAppNameFilter() {
        let windows = makeWindows()
        let result = engine.filter(windows, by: FilterCriteria(appName: "Safari"))
        XCTAssertTrue(result.allSatisfy { $0.appName == "Safari" })
        XCTAssertFalse(result.isEmpty)
    }

    // T-034: 模糊搜索 - 子串匹配
    func testFuzzySearchSubstring() {
        let windows = makeWindows()
        let result = engine.filter(windows, by: FilterCriteria(searchText: "saf"))
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy {
            $0.appName.lowercased().contains("saf") || $0.windowTitle.lowercased().contains("saf")
        })
    }

    // T-034: 模糊搜索 - 字符序列匹配
    func testFuzzySearchCharSequence() {
        let windows = makeWindows()
        // "sfr" 应匹配 "Safari"（s-a-f-a-r-i 包含 s,f,r 子序列）
        let result = engine.filter(windows, by: FilterCriteria(searchText: "sfr"))
        XCTAssertFalse(result.isEmpty)
    }

    // T-035: 空间筛选降级（无权限时不崩溃）
    func testSpaceFilterDegradation() {
        let windows = makeWindows()
        let criteria = FilterCriteria(currentSpaceOnly: true)
        // 无论 CGSSpace API 是否可用，不应崩溃，且返回结果
        XCTAssertNoThrow(engine.filter(windows, by: criteria))
    }

    // T-036: 排序 - 最近使用
    func testSortByRecent() {
        let windows = makeWindows()
        let sorted = engine.sort(windows, by: .recent)
        for i in 0..<sorted.count - 1 {
            XCTAssertGreaterThanOrEqual(sorted[i].lastActiveTime, sorted[i + 1].lastActiveTime)
        }
    }

    // T-036: 排序 - 应用名称
    func testSortByAppName() {
        let windows = makeWindows()
        let sorted = engine.sort(windows, by: .appName)
        for i in 0..<sorted.count - 1 {
            XCTAssertLessThanOrEqual(
                sorted[i].appName.localizedLowercase,
                sorted[i + 1].appName.localizedLowercase
            )
        }
    }

    // T-036: filterAndSort 便捷方法
    func testFilterAndSort() {
        let windows = makeWindows()
        let result = engine.filterAndSort(
            windows,
            criteria: FilterCriteria(searchText: ""),
            order: .appName
        )
        XCTAssertEqual(result.count, windows.count)
    }

    // 空列表边界
    func testEmptyInput() {
        XCTAssertTrue(engine.filter([], by: FilterCriteria()).isEmpty)
        XCTAssertTrue(engine.sort([], by: .recent).isEmpty)
    }

    // MARK: - Helpers
    private func makeWindows() -> [WindowModel] {
        let now = Date()
        return [
            makeWindow(id: 1, appName: "Safari",  title: "Apple",  offset: -1),
            makeWindow(id: 2, appName: "Chrome",  title: "Google", offset: -5),
            makeWindow(id: 3, appName: "Finder",  title: "Home",   offset: -10),
            makeWindow(id: 4, appName: "Xcode",   title: "Project",offset: -2),
            makeWindow(id: 5, appName: "Terminal",title: "zsh",    offset: -3),
        ]
    }

    private func makeWindow(id: CGWindowID, appName: String, title: String, offset: TimeInterval) -> WindowModel {
        WindowModel(
            id: id, appName: appName, bundleIdentifier: "com.\(appName.lowercased())",
            windowTitle: title, appIcon: NSImage(),
            frame: .zero, isMinimized: false, isHidden: false, isOnScreen: true,
            lastActiveTime: Date().addingTimeInterval(offset),
            windowLayer: 0, ownerPID: pid_t(id * 100)
        )
    }
}
