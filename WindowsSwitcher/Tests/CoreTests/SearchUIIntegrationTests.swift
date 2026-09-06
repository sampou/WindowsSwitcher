import XCTest
@testable import WindowsSwitcher

/// 切换面板顶部操作区的 SwiftUI 挂载契约测试。
///
/// 窗口搜索已经暂时下线；底层筛选引擎仍可独立测试，面板不得再挂载搜索输入控件。
@MainActor
final class SearchUIIntegrationTests: XCTestCase {
    func testSharedPanelHeightIncludesToolbarForSingleRow() {
        let height = SwitchPanelLayout.panelHeight(
            windowCount: 4,
            columnCount: 4,
            itemHeight: 200,
            screenHeight: 1_000,
            toolbarAreaHeight: SwitchPanelView.toolbarAreaHeight
        )

        XCTAssertEqual(height, 292)
    }

    func testSharedPanelHeightUsesRowsAndCapsAtEightyPercentOfScreen() {
        let uncappedHeight = SwitchPanelLayout.panelHeight(
            windowCount: 9,
            columnCount: 4,
            itemHeight: 100,
            screenHeight: 1_000,
            toolbarAreaHeight: SwitchPanelView.toolbarAreaHeight
        )
        let cappedHeight = SwitchPanelLayout.panelHeight(
            windowCount: 20,
            columnCount: 2,
            itemHeight: 200,
            screenHeight: 500,
            toolbarAreaHeight: SwitchPanelView.toolbarAreaHeight
        )

        XCTAssertEqual(uncappedHeight, 408)
        XCTAssertEqual(cappedHeight, 400)
    }

    func testSharedPanelHeightKeepsEmptyStateAboveToolbarAndBaseContentMinimum() {
        let height = SwitchPanelLayout.panelHeight(
            windowCount: 0,
            columnCount: 1,
            itemHeight: 40,
            screenHeight: 1_000,
            toolbarAreaHeight: SwitchPanelView.toolbarAreaHeight
        )

        XCTAssertGreaterThanOrEqual(
            height,
            SwitchPanelView.toolbarAreaHeight
                + SwitchPanelLayout.panelPadding * 2
                + SwitchPanelLayout.bottomBarHeight
        )
        XCTAssertEqual(height, SwitchPanelLayout.defaultMinimumHeight)
    }

    func testSwitchPanelBodyDoesNotMountSearchBar() {
        let panel = makePanel()

        let bodyType = String(reflecting: type(of: panel.body))

        XCTAssertFalse(bodyType.contains("SearchBarView"), "窗口搜索下线期间，切换面板不得挂载 SearchBarView")
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
