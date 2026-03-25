import XCTest
@testable import WindowsSwitcher

// MARK: - 应用分组排序测试
// 功能通过 SwitchPanelViewModel.selectNext() 动态实现

final class AppGroupSortTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConfigManager.shared.reset()
    }

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
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

    /// 测试 SortOrder 现有选项正常工作
    func testSortOrderOptionsWork() {
        ConfigManager.shared.updateBehavior { $0.sortOrder = .recent }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .recent)

        ConfigManager.shared.updateBehavior { $0.sortOrder = .appName }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .appName)

        ConfigManager.shared.updateBehavior { $0.sortOrder = .windowTitle }
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .windowTitle)
    }
}
