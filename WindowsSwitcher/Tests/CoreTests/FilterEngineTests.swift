import XCTest
@testable import WindowsSwitcher

// MARK: - T-040 筛选模块测试 / T-050 功能测试

final class FilterEngineAdvancedTests: XCTestCase {

    let engine = FilterEngine()

    // MARK: - 既有筛选与排序兼容行为（阶段一不得回归）

    // T-033: 精确应用名筛选
    func testCompatibilityFiltersByExactApplicationName() {
        let windows = makeWindows()
        let result = engine.filter(windows, by: FilterCriteria(appName: "Safari"))
        XCTAssertTrue(result.allSatisfy { $0.appName == "Safari" })
        XCTAssertFalse(result.isEmpty)
    }

    // T-034: 模糊搜索 - 子串匹配
    func testCompatibilityFuzzySearchMatchesSubstring() {
        let windows = makeWindows()
        let result = engine.filter(windows, by: FilterCriteria(searchText: "saf"))
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy {
            $0.appName.lowercased().contains("saf") || $0.windowTitle.lowercased().contains("saf")
        })
    }

    // T-034: 模糊搜索 - 字符序列匹配
    func testCompatibilityFuzzySearchMatchesCharacterSequence() {
        let windows = makeWindows()
        // "sfr" 应匹配 "Safari"（s-a-f-a-r-i 包含 s,f,r 子序列）
        let result = engine.filter(windows, by: FilterCriteria(searchText: "sfr"))
        XCTAssertFalse(result.isEmpty)
    }

    // T-035: 空间筛选降级（无权限时不崩溃）
    func testCompatibilitySpaceFilterDegradesWithoutCrashing() {
        let windows = makeWindows()
        let criteria = FilterCriteria(currentSpaceOnly: true)
        // 无论 CGSSpace API 是否可用，不应崩溃，且返回结果
        XCTAssertNoThrow(engine.filter(windows, by: criteria))
    }

    // T-036: 排序 - 最近使用
    func testCompatibilitySortsByRecentActivity() {
        let windows = makeWindows()
        let sorted = engine.sort(windows, by: .recent)
        for i in 0..<sorted.count - 1 {
            XCTAssertGreaterThanOrEqual(sorted[i].lastActiveTime, sorted[i + 1].lastActiveTime)
        }
    }

    // T-036: 排序 - 应用名称
    func testCompatibilitySortsByApplicationName() {
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
    func testCompatibilityFilterAndSortConvenienceMethod() {
        let windows = makeWindows()
        let result = engine.filterAndSort(
            windows,
            criteria: FilterCriteria(searchText: ""),
            order: .appName
        )
        XCTAssertEqual(result.count, windows.count)
    }

    // T-034: 兼容回归，搜索字段继续包含 Bundle Identifier。
    func testCompatibilitySearchIncludesBundleIdentifier() {
        let safari = makeWindow(id: 10, appName: "Safari", title: "Home", offset: 0)

        let result = engine.filterAndSort(
            [safari],
            criteria: FilterCriteria(searchText: "com.safari"),
            order: .recent
        )

        XCTAssertEqual(result.map(\.id), [10])
    }

    func testCompatibilityHandlesEmptyInput() {
        XCTAssertTrue(engine.filter([], by: FilterCriteria()).isEmpty)
        XCTAssertTrue(engine.sort([], by: .recent).isEmpty)
    }

    // MARK: - 阶段一新增评分、归一化与 MRU 决胜行为

    func testPhaseOneSearchRanksApplicationExactMatchBeforeTitleMatch() {
        let appExact = makeWindow(id: 10, appName: "Safari", title: "Home", offset: -10)
        let titleExact = makeWindow(id: 20, appName: "Notes", title: "Safari", offset: 0)

        let result = engine.filterAndSort(
            [titleExact, appExact],
            criteria: FilterCriteria(searchText: "Safari"),
            order: .recent
        )

        XCTAssertEqual(result.map(\.id), [10, 20])
    }

    func testPhaseOneSearchNormalizesWhitespaceAndDiacritics() {
        let cafe = makeWindow(id: 10, appName: "Café", title: "Menu", offset: 0)

        let result = engine.filterAndSort(
            [cafe],
            criteria: FilterCriteria(searchText: "  cafe  "),
            order: .recent
        )

        XCTAssertEqual(result.map(\.id), [10])
    }

    func testPhaseOneEqualSearchScoresUseConfiguredOrderingAndActivitySequence() {
        let first = makeWindow(id: 10, appName: "Notes", title: "Project Alpha", offset: 0)
        let second = makeWindow(id: 20, appName: "Mail", title: "Project Beta", offset: 0)

        let result = engine.filterAndSort(
            [first, second],
            criteria: FilterCriteria(searchText: "Project"),
            order: .recent,
            activitySequence: [10: 1, 20: 2]
        )

        XCTAssertEqual(result.map(\.id), [20, 10])
    }

    // MARK: - Helpers
    private func makeWindows() -> [WindowModel] {
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
