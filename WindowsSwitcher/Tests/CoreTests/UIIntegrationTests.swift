import XCTest
@testable import WindowsSwitcher

// MARK: - T-049 UI 集成测试

@MainActor
final class UIIntegrationTests: XCTestCase {

    var windowManager: WindowManager!
    var previewGenerator: PreviewGenerator!
    var filterEngine: FilterEngine!
    var viewModel: SwitchPanelViewModel!

    override func setUp() async throws {
        windowManager = WindowManager()
        previewGenerator = PreviewGenerator()
        filterEngine = FilterEngine()
        let windows = makeMockWindows()
        viewModel = SwitchPanelViewModel(
            windows: windows,
            windowManager: windowManager,
            previewGenerator: previewGenerator,
            filterEngine: filterEngine
        )
    }

    // MARK: - SwitchPanelViewModel 集成

    func testViewModelInitialState() {
        XCTAssertFalse(viewModel.filteredWindows.isEmpty)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertTrue(viewModel.searchText.isEmpty)
    }

    func testSelectNextWrapsAround() {
        let count = viewModel.filteredWindows.count
        for _ in 0..<count { viewModel.selectNext() }
        XCTAssertEqual(viewModel.selectedIndex, 0, "循环后应回到第一个")
    }

    func testSelectPreviousWrapsAround() {
        viewModel.selectPrevious()
        XCTAssertEqual(viewModel.selectedIndex, viewModel.filteredWindows.count - 1)
    }

    func testSearchFilterUpdatesFilteredWindows() {
        let total = viewModel.filteredWindows.count
        viewModel.searchText = "Safari"
        XCTAssertLessThanOrEqual(viewModel.filteredWindows.count, total)
        XCTAssertTrue(viewModel.filteredWindows.allSatisfy {
            $0.appName.lowercased().contains("safari") || $0.windowTitle.lowercased().contains("safari")
        })
    }

    func testSearchClearRestoresAll() {
        let total = viewModel.filteredWindows.count
        viewModel.searchText = "zzznomatch"
        XCTAssertTrue(viewModel.filteredWindows.isEmpty)
        viewModel.searchText = ""
        XCTAssertEqual(viewModel.filteredWindows.count, total)
    }

    func testSelectedWindowMatchesIndex() {
        viewModel.selectNext()
        XCTAssertEqual(viewModel.selectedWindow?.id, viewModel.filteredWindows[viewModel.selectedIndex].id)
    }

    func testCloseWindowRemovesFromList() {
        guard let first = viewModel.filteredWindows.first else { return }
        let countBefore = viewModel.filteredWindows.count
        viewModel.closeWindow(first)
        // 乐观移除后立即检查
        XCTAssertEqual(viewModel.filteredWindows.count, countBefore - 1)
        XCTAssertFalse(viewModel.filteredWindows.contains { $0.id == first.id })
    }

    func testMinimizeWindowRemovesFromList() {
        guard let first = viewModel.filteredWindows.first else { return }
        let countBefore = viewModel.filteredWindows.count
        viewModel.minimizeWindow(first)
        XCTAssertEqual(viewModel.filteredWindows.count, countBefore - 1)
    }

    func testHideWindowRemovesFromList() {
        guard let first = viewModel.filteredWindows.first else { return }
        let countBefore = viewModel.filteredWindows.count
        viewModel.hideWindow(first)
        XCTAssertEqual(viewModel.filteredWindows.count, countBefore - 1)
    }

    // MARK: - appSwitch 应用内切换集成

    func testSwitchWithinCurrentAppDoesNotCrash() {
        // 无前台应用时不崩溃
        XCTAssertNoThrow(viewModel.switchWithinCurrentApp())
    }

    // MARK: - FilterEngine + ViewModel 集成

    func testSortOrderChangeTakesEffect() {
        ConfigManager.shared.config.behavior.sortOrder = .appName
        viewModel.applyFilter()
        let names = viewModel.filteredWindows.map { $0.appName }
        for i in 0..<names.count - 1 {
            XCTAssertLessThanOrEqual(names[i].localizedLowercase, names[i+1].localizedLowercase)
        }
        // 恢复默认
        ConfigManager.shared.config.behavior.sortOrder = .recent
    }

    func testShowMinimizedToggle() {
        ConfigManager.shared.config.behavior.showMinimizedWindows = false
        viewModel.applyFilter()
        XCTAssertFalse(viewModel.filteredWindows.contains { $0.isMinimized })
        ConfigManager.shared.config.behavior.showMinimizedWindows = true
    }

    // MARK: - DesignTokens 集成验证

    func testDesignTokensPanelDimensions() {
        XCTAssertEqual(DesignTokens.Panel.width, 720)
        XCTAssertEqual(DesignTokens.Panel.height, 480)
        XCTAssertEqual(DesignTokens.Panel.cornerRadius, 12)
    }

    func testDesignTokensWindowItemDimensions() {
        XCTAssertEqual(DesignTokens.WindowItem.width, 160)
        XCTAssertEqual(DesignTokens.WindowItem.height, 140)
        XCTAssertEqual(DesignTokens.WindowItem.previewHeight, 81) // 16:9
    }

    // MARK: - ConfigManager 集成

    func testConfigPersistsAcrossReset() throws {
        ConfigManager.shared.config.appearance.panelOpacity = 0.7
        let saved = ConfigManager.shared.config.appearance.panelOpacity
        ConfigManager.shared.reset()
        XCTAssertEqual(ConfigManager.shared.config.appearance.panelOpacity, 0.95, "重置后应恢复默认值")
        _ = saved // suppress warning
    }

    // MARK: - Helpers

    private func makeMockWindows() -> [WindowModel] {
        [
            makeWindow(id: 1, app: "Safari",   title: "Apple",   minimized: false),
            makeWindow(id: 2, app: "Chrome",   title: "Google",  minimized: false),
            makeWindow(id: 3, app: "Finder",   title: "Home",    minimized: true),
            makeWindow(id: 4, app: "Xcode",    title: "Project", minimized: false),
            makeWindow(id: 5, app: "Terminal", title: "zsh",     minimized: false),
        ]
    }

    private func makeWindow(id: CGWindowID, app: String, title: String, minimized: Bool) -> WindowModel {
        WindowModel(
            id: id, appName: app, bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: title, appIcon: NSImage(),
            frame: .zero, isMinimized: minimized, isHidden: false, isOnScreen: !minimized,
            lastActiveTime: Date().addingTimeInterval(-Double(id)),
            windowLayer: 0, ownerPID: pid_t(id * 100)
        )
    }
}
