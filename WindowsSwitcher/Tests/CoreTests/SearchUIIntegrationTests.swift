import XCTest
@testable import WindowsSwitcher

/// 搜索栏的 SwiftUI 挂载与绑定契约测试。
///
/// 这些测试验证组件结构和 Binding 到 ViewModel 的连接，不模拟鼠标、键盘或系统焦点，
/// 因此不属于真实 UI E2E 测试。
@MainActor
final class SearchUIIntegrationTests: XCTestCase {
    func testSharedPanelHeightIncludesSearchAreaForSingleRow() {
        let height = SwitchPanelLayout.panelHeight(
            windowCount: 4,
            columnCount: 4,
            itemHeight: 200,
            screenHeight: 1_000,
            searchAreaHeight: SwitchPanelView.searchAreaHeight
        )

        XCTAssertEqual(height, 292)
    }

    func testSharedPanelHeightUsesRowsAndCapsAtEightyPercentOfScreen() {
        let uncappedHeight = SwitchPanelLayout.panelHeight(
            windowCount: 9,
            columnCount: 4,
            itemHeight: 100,
            screenHeight: 1_000,
            searchAreaHeight: SwitchPanelView.searchAreaHeight
        )
        let cappedHeight = SwitchPanelLayout.panelHeight(
            windowCount: 20,
            columnCount: 2,
            itemHeight: 200,
            screenHeight: 500,
            searchAreaHeight: SwitchPanelView.searchAreaHeight
        )

        XCTAssertEqual(uncappedHeight, 408)
        XCTAssertEqual(cappedHeight, 400)
    }

    func testSharedPanelHeightKeepsEmptyStateAboveSearchAndBaseContentMinimum() {
        let height = SwitchPanelLayout.panelHeight(
            windowCount: 0,
            columnCount: 1,
            itemHeight: 40,
            screenHeight: 1_000,
            searchAreaHeight: SwitchPanelView.searchAreaHeight
        )

        XCTAssertGreaterThanOrEqual(
            height,
            SwitchPanelView.searchAreaHeight
                + SwitchPanelLayout.panelPadding * 2
                + SwitchPanelLayout.bottomBarHeight
        )
        XCTAssertEqual(height, SwitchPanelLayout.defaultMinimumHeight)
    }

    func testSearchBarExposesProductCopyAndAccessibilityContract() {
        XCTAssertEqual(SearchBarView.defaultPlaceholder, "搜索应用、窗口或 Bundle ID...")
        XCTAssertEqual(SearchBarView.searchAccessibilityLabel, "搜索窗口")
        XCTAssertEqual(
            SearchBarView.searchAccessibilityHint,
            "输入应用名称、窗口标题或 Bundle Identifier 搜索"
        )
    }

    func testSwitchPanelBodyMountsSearchBar() {
        let panel = makePanel()

        let bodyType = String(reflecting: type(of: panel.body))

        XCTAssertTrue(bodyType.contains("SearchBarView"), "切换面板必须实际挂载 SearchBarView")
    }

    func testPanelSearchBindingFiltersApplicationTitleAndBundleIdentifier() {
        let panel = makePanel()
        let binding = panel.searchTextBinding

        XCTAssertEqual(binding.wrappedValue, "")
        XCTAssertEqual(panel.viewModel.filteredWindows.count, 3, "空搜索应保留现有窗口集合")

        binding.wrappedValue = "Atlas"
        XCTAssertEqual(panel.viewModel.filteredWindows.map(\.id), [1])

        binding.wrappedValue = "Quarterly Roadmap"
        XCTAssertEqual(panel.viewModel.filteredWindows.map(\.id), [2])

        binding.wrappedValue = "com.example.terminal"
        XCTAssertEqual(panel.viewModel.filteredWindows.map(\.id), [3])

        binding.wrappedValue = ""
        XCTAssertEqual(panel.viewModel.filteredWindows.count, 3, "清空搜索应恢复原有窗口集合")
    }

    private func makePanel() -> SwitchPanelView {
        let windows = [
            makeWindow(id: 1, appName: "Atlas", bundleIdentifier: "com.example.atlas", title: "Home"),
            makeWindow(id: 2, appName: "Notes", bundleIdentifier: "com.example.notes", title: "Quarterly Roadmap"),
            makeWindow(id: 3, appName: "Terminal", bundleIdentifier: "com.example.terminal", title: "zsh")
        ]
        let manager = SearchUIWindowManager(windows: windows)
        let viewModel = SwitchPanelViewModel(
            windows: windows,
            windowManager: manager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
        return SwitchPanelView(viewModel: viewModel, onDismiss: {})
    }

    private func makeWindow(
        id: CGWindowID,
        appName: String,
        bundleIdentifier: String,
        title: String
    ) -> WindowModel {
        WindowModel(
            id: id,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: title,
            appIcon: NSImage(),
            frame: .zero,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(timeIntervalSince1970: TimeInterval(id)),
            windowLayer: 0,
            ownerPID: pid_t(id)
        )
    }
}

private final class SearchUIWindowManager: WindowManagerProtocol, @unchecked Sendable {
    let windows: [WindowModel]

    init(windows: [WindowModel]) {
        self.windows = windows
    }

    func getAllWindows(forceRefresh: Bool) -> [WindowModel] { windows }
    func activitySequenceSnapshot() -> [CGWindowID: UInt64] { [:] }
    func activateWindow(_ window: WindowModel) {}
    func closeWindow(_ window: WindowModel) {}
    func minimizeWindow(_ window: WindowModel) {}
    func hideWindow(_ window: WindowModel) {}
    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {}
    func refreshCache() {}
}
