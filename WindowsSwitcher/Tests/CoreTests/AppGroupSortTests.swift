import XCTest
@testable import WindowsSwitcher

// MARK: - 应用分组排序模式测试

final class AppGroupSortTests: XCTestCase {

    var filterEngine: FilterEngine!

    override func setUp() {
        super.setUp()
        filterEngine = FilterEngine()
        ConfigManager.shared.reset()
    }

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
    }

    // MARK: - 测试用例

    /// 测试1：应用分组排序 - 基本功能
    func testAppGroupSortBasic() {
        // 创建模拟窗口：Safari 2个，Chrome 2个，Finder 1个
        let windows = [
            makeWindow(id: 1, app: "Safari", bundleID: "com.apple.Safari", activeTime: Date().addingTimeInterval(-100)),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: Date().addingTimeInterval(-50)),
            makeWindow(id: 3, app: "Chrome", bundleID: "com.google.Chrome", activeTime: Date().addingTimeInterval(-200)),
            makeWindow(id: 4, app: "Chrome", bundleID: "com.google.Chrome", activeTime: Date().addingTimeInterval(-150)),
            makeWindow(id: 5, app: "Finder", bundleID: "com.apple.Finder", activeTime: Date().addingTimeInterval(-300)),
        ]

        // 按应用分组排序（不指定目标应用）
        let sorted = filterEngine.sortByAppGroup(windows, targetAppBundleID: nil)

        // 验证：最活跃应用的窗口在前
        // 最活跃的是 Safari（最近活跃时间 -50）
        XCTAssertEqual(sorted.first?.appName, "Safari", "最活跃应用的窗口应该在第一位")
        XCTAssertEqual(sorted.count, 5, "窗口总数应该不变")

        // 验证 Safari 窗口都在前面
        let safariCount = sorted.prefix(2).filter { $0.appName == "Safari" }.count
        XCTAssertEqual(safariCount, 2, "Safari 的两个窗口应该在前两位")
    }

    /// 测试2：应用分组排序 - 指定目标应用
    func testAppGroupSortWithTargetApp() {
        let now = Date()
        let windows = [
            makeWindow(id: 1, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-100)),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-50)),
            makeWindow(id: 3, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-200)),
            makeWindow(id: 4, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-150)),
        ]

        // 指定目标应用为 Chrome
        let sorted = filterEngine.sortByAppGroupWithTarget(windows, targetAppBundleID: "com.google.Chrome")

        // 验证：Chrome 窗口在前
        XCTAssertEqual(sorted.first?.appName, "Chrome", "目标应用的窗口应该在第一位")
        XCTAssertTrue(sorted.prefix(2).allSatisfy { $0.appName == "Chrome" }, "Chrome 的窗口应该在前两位")

        // 验证：Safari 窗口在后
        XCTAssertTrue(sorted.suffix(2).allSatisfy { $0.appName == "Safari" }, "其他应用的窗口应该在后面")
    }

    /// 测试3：应用分组排序 - 窗口顺序正确性
    func testAppGroupSortWindowOrderWithinApp() {
        let now = Date()
        let windows = [
            makeWindow(id: 1, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-100)),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-10)), // 最活跃
            makeWindow(id: 3, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-50)),
        ]

        let sorted = filterEngine.sortByAppGroup(windows, targetAppBundleID: nil)

        // Safari 最活跃，其窗口在前
        XCTAssertEqual(sorted[0].id, 2, "Safari 最活跃的窗口应该在第一位")
        XCTAssertEqual(sorted[1].id, 1, "Safari 次活跃的窗口应该在第二位")
        XCTAssertEqual(sorted[2].appName, "Chrome", "其他应用的窗口在后面")
    }

    /// 测试4：应用分组排序 - 从应用A切换到应用B后重新排列
    func testAppGroupSortAfterSwitchingApps() {
        let now = Date()
        let windows = [
            // Safari 窗口（当前活跃应用）
            makeWindow(id: 1, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-5)),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: now.addingTimeInterval(-100)),
            // Chrome 窗口
            makeWindow(id: 3, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-200)),
            makeWindow(id: 4, app: "Chrome", bundleID: "com.google.Chrome", activeTime: now.addingTimeInterval(-250)),
        ]

        // 初始状态：Safari 最活跃
        let initialSorted = filterEngine.sortByAppGroup(windows, targetAppBundleID: nil)
        XCTAssertEqual(initialSorted.first?.appName, "Safari", "初始状态 Safari 在前")

        // 模拟切换到 Chrome 后重新排序
        let afterSwitchSorted = filterEngine.sortByAppGroupWithTarget(windows, targetAppBundleID: "com.google.Chrome")

        // 验证：Chrome 窗口现在在前
        XCTAssertEqual(afterSwitchSorted.first?.appName, "Chrome", "切换后 Chrome 在前")
        XCTAssertTrue(afterSwitchSorted.prefix(2).allSatisfy { $0.appName == "Chrome" }, "Chrome 所有窗口在前")

        // 验证：Safari 窗口移到后面
        XCTAssertTrue(afterSwitchSorted.suffix(2).allSatisfy { $0.appName == "Safari" }, "Safari 窗口移到后面")
    }

    /// 测试5：应用分组排序 - 单个应用
    func testAppGroupSortSingleApp() {
        let windows = [
            makeWindow(id: 1, app: "Safari", bundleID: "com.apple.Safari", activeTime: Date().addingTimeInterval(-100)),
            makeWindow(id: 2, app: "Safari", bundleID: "com.apple.Safari", activeTime: Date().addingTimeInterval(-50)),
        ]

        let sorted = filterEngine.sortByAppGroup(windows, targetAppBundleID: nil)

        XCTAssertEqual(sorted.count, 2, "窗口数量应该不变")
        XCTAssertEqual(sorted.first?.id, 2, "最活跃的窗口在前")
    }

    /// 测试6：应用分组排序 - 空窗口列表
    func testAppGroupSortEmpty() {
        let sorted = filterEngine.sortByAppGroup([], targetAppBundleID: nil)
        XCTAssertTrue(sorted.isEmpty, "空列表应该返回空")
    }

    /// 测试7：设置中启用应用分组排序
    func testEnableAppGroupSortInSettings() {
        // 验证 SortOrder 枚举包含 appGroup
        XCTAssertTrue(SortOrder.allCases.contains(.appGroup), "SortOrder 应包含 appGroup")

        // 设置排序方式为应用分组
        ConfigManager.shared.updateBehavior { $0.sortOrder = .appGroup }

        // 验证设置生效
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .appGroup, "排序方式应为应用分组")
    }

    /// 测试8：排序顺序切换
    func testSwitchSortOrder() {
        // 设置为应用分组
        ConfigManager.shared.updateBehavior { $0.sortOrder = .appGroup }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .appGroup)

        // 切换到最近使用
        ConfigManager.shared.updateBehavior { $0.sortOrder = .recent }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .recent)

        // 切换回应用分组
        ConfigManager.shared.updateBehavior { $0.sortOrder = .appGroup }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .appGroup)
    }

    // MARK: - 辅助方法

    private func makeWindow(id: CGWindowID, app: String, bundleID: String, activeTime: Date) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: bundleID,
            windowTitle: "\(app) Window \(id)",
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
}
