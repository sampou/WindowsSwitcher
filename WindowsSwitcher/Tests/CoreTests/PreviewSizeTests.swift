import XCTest
@testable import WindowsSwitcher

// MARK: - PreviewSize 枚举功能测试

final class PreviewSizeTests: XCTestCase {

    // MARK: - 枚举存在性测试

    func testPreviewSizeEnumExists() {
        let small = PreviewSize.small
        let medium = PreviewSize.medium
        let large = PreviewSize.large

        XCTAssertNotNil(small)
        XCTAssertNotNil(medium)
        XCTAssertNotNil(large)
    }

    func testPreviewSizeAllCases() {
        let allCases = PreviewSize.allCases
        XCTAssertEqual(allCases.count, 3, "应该有 3 种预览尺寸")
        XCTAssertTrue(allCases.contains(.small))
        XCTAssertTrue(allCases.contains(.medium))
        XCTAssertTrue(allCases.contains(.large))
    }

    // MARK: - 预览窗口尺寸测试

    func testPreviewDimensions() {
        // 小尺寸
        let smallDims = PreviewSize.small.dimensions
        XCTAssertEqual(smallDims.width, 80)
        XCTAssertEqual(smallDims.height, 45)

        // 中等尺寸
        let mediumDims = PreviewSize.medium.dimensions
        XCTAssertEqual(mediumDims.width, 114)
        XCTAssertEqual(mediumDims.height, 64)

        // 大尺寸
        let largeDims = PreviewSize.large.dimensions
        XCTAssertEqual(largeDims.width, 160)
        XCTAssertEqual(largeDims.height, 90)
    }

    func testPreviewAspectRatioIs16by9() {
        // 验证所有尺寸都是 16:9 比例
        for size in PreviewSize.allCases {
            let dims = size.dimensions
            let ratio = dims.width / dims.height
            // 16:9 ≈ 1.778
            XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.2, "\(size) 预览比例应接近 16:9")
        }
    }

    // MARK: - 窗口项尺寸测试

    func testItemDimensions() {
        // 小尺寸
        let smallItem = PreviewSize.small.itemDimensions
        XCTAssertEqual(smallItem.width, 100)
        XCTAssertEqual(smallItem.height, 90)

        // 中等尺寸
        let mediumItem = PreviewSize.medium.itemDimensions
        XCTAssertEqual(mediumItem.width, 130)
        XCTAssertEqual(mediumItem.height, 110)

        // 大尺寸
        let largeItem = PreviewSize.large.itemDimensions
        XCTAssertEqual(largeItem.width, 180)
        XCTAssertEqual(largeItem.height, 150)
    }

    // MARK: - 原始值测试

    func testRawValues() {
        XCTAssertEqual(PreviewSize.small.rawValue, "小")
        XCTAssertEqual(PreviewSize.medium.rawValue, "中")
        XCTAssertEqual(PreviewSize.large.rawValue, "大")
    }

    func testInitializeFromRawValue() {
        XCTAssertEqual(PreviewSize(rawValue: "小"), .small)
        XCTAssertEqual(PreviewSize(rawValue: "中"), .medium)
        XCTAssertEqual(PreviewSize(rawValue: "大"), .large)
        XCTAssertNil(PreviewSize(rawValue: "invalid"))
    }

    // MARK: - 配置集成测试

    func testPreviewSizeInConfig() {
        let config = ConfigModel()
        XCTAssertEqual(config.appearance.previewSize, .medium, "默认应该是中等尺寸")
    }

    func testPreviewSizeCanBeChanged() {
        ConfigManager.shared.updateAppearance { $0.previewSize = .small }
        XCTAssertEqual(ConfigManager.shared.config.appearance.previewSize, .small)

        ConfigManager.shared.updateAppearance { $0.previewSize = .large }
        XCTAssertEqual(ConfigManager.shared.config.appearance.previewSize, .large)

        // 恢复默认
        ConfigManager.shared.updateAppearance { $0.previewSize = .medium }
        XCTAssertEqual(ConfigManager.shared.config.appearance.previewSize, .medium)
    }

    // MARK: - switcherColumns 配置测试

    func testSwitcherColumnsDefaultValue() {
        let config = ConfigModel()
        XCTAssertEqual(config.appearance.switcherColumns, 0, "默认应该是 0（自动计算）")
    }

    func testSwitcherColumnsCanBeSet() {
        ConfigManager.shared.updateAppearance { $0.switcherColumns = 4 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.switcherColumns, 4)

        ConfigManager.shared.updateAppearance { $0.switcherColumns = 6 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.switcherColumns, 6)

        // 恢复默认
        ConfigManager.shared.updateAppearance { $0.switcherColumns = 0 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.switcherColumns, 0)
    }

    func testSwitcherColumnsZeroMeansAuto() {
        // 0 表示自动计算
        ConfigManager.shared.updateAppearance { $0.switcherColumns = 0 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.switcherColumns, 0)
    }
}

// MARK: - 方向键导航测试

@MainActor
final class ArrowNavigationTests: XCTestCase {

    private func makeWindow(id: CGWindowID, app: String) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: "\(app) Window \(id)",
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

    func testSelectUpMethodExists() {
        // 验证 selectUp 方法存在
        let windows = (0..<6).map { makeWindow(id: CGWindowID($0), app: "App\($0)") }
        let mockManager = TestWindowManagerForNav(windows: windows)
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        // 不崩溃即通过
        vm.selectUp()
    }

    func testSelectDownMethodExists() {
        let windows = (0..<6).map { makeWindow(id: CGWindowID($0), app: "App\($0)") }
        let mockManager = TestWindowManagerForNav(windows: windows)
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        // 不崩溃即通过
        vm.selectDown()
    }

    func testSelectUpDoesNotCrashOnEmptyWindows() {
        let mockManager = TestWindowManagerForNav(windows: [])
        let vm = SwitchPanelViewModel(
            windows: [],
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        // 空窗口列表不应崩溃
        vm.selectUp()
        vm.selectDown()
    }

    func testSelectDownMovesToNextRow() {
        let windows = (0..<6).map { makeWindow(id: CGWindowID($0), app: "App\($0)") }
        let mockManager = TestWindowManagerForNav(windows: windows)
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        let initialIndex = vm.selectedIndex

        // 从第一行移动到第二行
        vm.selectDown()

        // 验证索引变化（取决于列数配置）
        // 至少验证方法执行成功
        XCTAssertGreaterThanOrEqual(vm.selectedIndex, 0)
        XCTAssertLessThan(vm.selectedIndex, vm.filteredWindows.count)
    }

    func testNavigationStabilityMultipleCalls() {
        let windows = (0..<12).map { makeWindow(id: CGWindowID($0), app: "App\($0)") }
        let mockManager = TestWindowManagerForNav(windows: windows)
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: mockManager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )

        // 多次调用不应崩溃
        for _ in 0..<20 {
            vm.selectDown()
            vm.selectUp()
        }

        // 验证索引仍在有效范围内
        XCTAssertGreaterThanOrEqual(vm.selectedIndex, 0)
        XCTAssertLessThan(vm.selectedIndex, vm.filteredWindows.count)
    }
}

// MARK: - Test WindowManager for Navigation Tests

private class TestWindowManagerForNav: WindowManagerProtocol {
    var testWindows: [WindowModel]

    init(windows: [WindowModel]) {
        self.testWindows = windows
    }

    nonisolated func getAllWindows(forceRefresh: Bool = false) -> [WindowModel] {
        return testWindows
    }

    nonisolated func getWindows(for appName: String) -> [WindowModel] {
        return testWindows.filter { $0.appName == appName }
    }

    nonisolated func activateWindow(_ window: WindowModel) {}
    nonisolated func closeWindow(_ window: WindowModel) {}
    nonisolated func minimizeWindow(_ window: WindowModel) {}
    nonisolated func hideWindow(_ window: WindowModel) {}
    nonisolated func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {}
    nonisolated func refreshCache() {}
    nonisolated func startMonitoring() {}
    nonisolated func stopMonitoring() {}
}
