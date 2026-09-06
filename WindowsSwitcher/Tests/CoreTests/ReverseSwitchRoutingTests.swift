import XCTest
@testable import WindowsSwitcher

/// 反向切换的通知路由与索引状态测试。
///
/// 这些用例直接驱动 ViewModel 或发送应用内部通知，不模拟系统全局快捷键，
/// 因此不属于真实热键 E2E 测试。
@MainActor
final class ReverseSwitchRoutingTests: XCTestCase {
    func testReverseSwitchNotificationRoutesToSelectPrevious() {
        let viewModel = makeViewModel()
        viewModel.selectedIndex = 2

        NotificationCenter.default.post(name: .reverseSwitchHotKeyPressed, object: nil)
        drainNotificationQueue()

        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(viewModel.selectedWindowID, 2)
    }

    func testSelectPreviousWrapsFromFirstIndexToLast() {
        let viewModel = makeViewModel()
        viewModel.selectedIndex = 0

        viewModel.selectPrevious()

        XCTAssertEqual(viewModel.selectedIndex, 2)
        XCTAssertEqual(viewModel.selectedWindowID, 3)
    }

    func testExplicitSelectionKeepsIndexAndWindowIDInSync() {
        let viewModel = makeViewModel()

        let selected = viewModel.selectWindow(at: 2)

        XCTAssertEqual(selected?.id, 3)
        XCTAssertEqual(viewModel.selectedIndex, 2)
        XCTAssertEqual(viewModel.selectedWindowID, 3)
    }

    func testSameAppReverseWrapsFromFirstIndexToLast() {
        let viewModel = makeViewModel()
        viewModel.beginSameAppSwitchSession(
            bundleIdentifier: "com.example.editor",
            initialIndex: 0
        )

        viewModel.advanceSameAppSwitchSession(reversed: true)

        XCTAssertEqual(viewModel.sameAppSwitchSession?.selectedIndex, 2)
        XCTAssertEqual(viewModel.selectedWindowID, 3)
    }

    func testForwardThenReverseRestoresSelection() {
        let viewModel = makeViewModel()
        viewModel.selectedIndex = 1

        viewModel.selectNext()
        XCTAssertEqual(viewModel.selectedIndex, 2)

        viewModel.selectPrevious()

        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(viewModel.selectedWindowID, 2)
    }

    func testAppSwitchReverseNotificationRoutesToSameAppReverseAdvance() {
        let viewModel = makeViewModel()
        viewModel.beginSameAppSwitchSession(
            bundleIdentifier: "com.example.editor",
            initialIndex: 0
        )

        NotificationCenter.default.post(name: .appSwitchReverseHotKeyPressed, object: nil)
        drainNotificationQueue()

        XCTAssertEqual(viewModel.sameAppSwitchSession?.selectedIndex, 2)
        XCTAssertEqual(viewModel.selectedWindowID, 3)
    }

    private func makeViewModel() -> SwitchPanelViewModel {
        let windows = [
            makeWindow(id: 1),
            makeWindow(id: 2),
            makeWindow(id: 3)
        ]
        let manager = ReverseSwitchWindowManager(
            windows: windows,
            activitySequence: [1: 3, 2: 2, 3: 1]
        )
        return SwitchPanelViewModel(
            windows: windows,
            windowManager: manager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
    }

    private func makeWindow(id: CGWindowID) -> WindowModel {
        WindowModel(
            id: id,
            appName: "Editor",
            bundleIdentifier: "com.example.editor",
            windowTitle: "Window \(id)",
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

    private func drainNotificationQueue() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}

private final class ReverseSwitchWindowManager: WindowManagerProtocol, @unchecked Sendable {
    let windows: [WindowModel]
    let activitySequence: [CGWindowID: UInt64]

    init(windows: [WindowModel], activitySequence: [CGWindowID: UInt64]) {
        self.windows = windows
        self.activitySequence = activitySequence
    }

    func getAllWindows(forceRefresh: Bool) -> [WindowModel] { windows }
    func activitySequenceSnapshot() -> [CGWindowID: UInt64] { activitySequence }
    func activateWindow(_ window: WindowModel) {}
    func closeWindow(_ window: WindowModel) {}
    func minimizeWindow(_ window: WindowModel) {}
    func hideWindow(_ window: WindowModel) {}
    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {}
    func refreshCache() {}
}
