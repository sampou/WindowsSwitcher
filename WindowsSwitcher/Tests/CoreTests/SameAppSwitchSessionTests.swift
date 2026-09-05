import XCTest
@testable import WindowsSwitcher

@MainActor
final class SameAppSwitchSessionTests: XCTestCase {
    func testInitialSelectionIndexCoversPriorityBranches() {
        XCTAssertEqual(SwitchPanelViewModel.initialSelectionIndex(windowCount: 0, reversed: true, appSwitchMode: true, defaultSelectSecond: true), 0)
        XCTAssertEqual(SwitchPanelViewModel.initialSelectionIndex(windowCount: 1, reversed: true, appSwitchMode: true, defaultSelectSecond: true), 0)
        XCTAssertEqual(SwitchPanelViewModel.initialSelectionIndex(windowCount: 2, reversed: true, appSwitchMode: false, defaultSelectSecond: false), 1)
        XCTAssertEqual(SwitchPanelViewModel.initialSelectionIndex(windowCount: 5, reversed: true, appSwitchMode: false, defaultSelectSecond: false), 4)
        XCTAssertEqual(SwitchPanelViewModel.initialSelectionIndex(windowCount: 2, reversed: false, appSwitchMode: true, defaultSelectSecond: false), 1)
        XCTAssertEqual(SwitchPanelViewModel.initialSelectionIndex(windowCount: 2, reversed: false, appSwitchMode: false, defaultSelectSecond: true), 1)
        XCTAssertEqual(SwitchPanelViewModel.initialSelectionIndex(windowCount: 2, reversed: false, appSwitchMode: false, defaultSelectSecond: false), 0)
    }

    func testSessionScopesByBundleIdentifierAndFreezesOrder() {
        let windows = [
            makeWindow(id: 1, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 2, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 3, app: "Editor", bundleID: "com.other.editor")
        ]
        let manager = SessionWindowManager(windows: windows, sequence: [1: 3, 2: 2, 3: 99])
        let viewModel = makeViewModel(windows: windows, manager: manager)

        viewModel.beginSameAppSwitchSession(bundleIdentifier: "com.example.editor", initialIndex: 1)

        XCTAssertEqual(viewModel.sameAppSwitchSession?.windowIDs, [1, 2])
        XCTAssertEqual(viewModel.filteredWindows.map(\.id), [1, 2])
        XCTAssertEqual(viewModel.selectedWindowID, 2)

        manager.sequence = [1: 1, 2: 100]
        viewModel.advanceSameAppSwitchSession(reversed: false)
        XCTAssertEqual(viewModel.sameAppSwitchSession?.windowIDs, [1, 2])
        XCTAssertEqual(viewModel.selectedWindowID, 1)
        viewModel.advanceSameAppSwitchSession(reversed: true)
        XCTAssertEqual(viewModel.selectedWindowID, 2)
    }

    func testRefreshReconcilesClosedWindowWithoutAddingNewSessionMembers() {
        let initial = [
            makeWindow(id: 1, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 2, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 3, app: "Editor", bundleID: "com.example.editor")
        ]
        let manager = SessionWindowManager(windows: initial, sequence: [1: 3, 2: 2, 3: 1])
        let viewModel = makeViewModel(windows: initial, manager: manager)
        viewModel.beginSameAppSwitchSession(bundleIdentifier: "com.example.editor", initialIndex: 1)

        manager.windows = [
            initial[1],
            initial[2],
            makeWindow(id: 4, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 9, app: "Other", bundleID: "com.example.other")
        ]
        manager.sequence = [2: 2, 3: 1, 4: 100, 9: 200]
        viewModel.refreshWindows()

        XCTAssertEqual(viewModel.sameAppSwitchSession?.windowIDs, [2, 3])
        XCTAssertEqual(viewModel.filteredWindows.map(\.id), [2, 3])
        XCTAssertEqual(viewModel.selectedWindowID, 2)
    }

    func testSessionEndsWhenFewerThanTwoOriginalWindowsRemain() {
        let initial = [
            makeWindow(id: 1, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 2, app: "Editor", bundleID: "com.example.editor")
        ]
        let manager = SessionWindowManager(windows: initial, sequence: [1: 2, 2: 1])
        let viewModel = makeViewModel(windows: initial, manager: manager)
        viewModel.beginSameAppSwitchSession(bundleIdentifier: "com.example.editor", initialIndex: 1)

        manager.windows = [initial[0]]
        viewModel.refreshWindows()

        XCTAssertNil(viewModel.sameAppSwitchSession)
        XCTAssertEqual(viewModel.filteredWindows.map(\.id), [1])
    }

    func testEndSessionClearsFrozenState() {
        let windows = [
            makeWindow(id: 1, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 2, app: "Editor", bundleID: "com.example.editor")
        ]
        let manager = SessionWindowManager(windows: windows, sequence: [1: 2, 2: 1])
        let viewModel = makeViewModel(windows: windows, manager: manager)
        viewModel.beginSameAppSwitchSession(bundleIdentifier: "com.example.editor", initialIndex: 1)

        viewModel.endSameAppSwitchSession()

        XCTAssertNil(viewModel.sameAppSwitchSession)
    }

    func testBeginAfterEndBuildsIndependentSessionFromLatestWindows() {
        let initial = [
            makeWindow(id: 1, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 2, app: "Editor", bundleID: "com.example.editor")
        ]
        let manager = SessionWindowManager(windows: initial, sequence: [1: 2, 2: 1])
        let viewModel = makeViewModel(windows: initial, manager: manager)
        viewModel.beginSameAppSwitchSession(bundleIdentifier: "com.example.editor", initialIndex: 1)
        XCTAssertEqual(viewModel.sameAppSwitchSession?.windowIDs, [1, 2])

        viewModel.endSameAppSwitchSession()
        manager.windows = [
            initial[1],
            makeWindow(id: 3, app: "Editor", bundleID: "com.example.editor")
        ]
        manager.sequence = [2: 1, 3: 3]
        viewModel.refreshWindows()
        viewModel.beginSameAppSwitchSession(bundleIdentifier: "com.example.editor", initialIndex: 0)

        XCTAssertEqual(viewModel.sameAppSwitchSession?.windowIDs, [3, 2])
        XCTAssertEqual(viewModel.filteredWindows.map(\.id), [3, 2])
        XCTAssertEqual(viewModel.selectedWindowID, 3)
    }

    func testActivationSkipsSelectedWindowThatClosedDuringSession() {
        let initial = [
            makeWindow(id: 1, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 2, app: "Editor", bundleID: "com.example.editor"),
            makeWindow(id: 3, app: "Editor", bundleID: "com.example.editor")
        ]
        let manager = SessionWindowManager(windows: initial, sequence: [1: 3, 2: 2, 3: 1])
        let viewModel = makeViewModel(windows: initial, manager: manager)
        viewModel.beginSameAppSwitchSession(bundleIdentifier: "com.example.editor", initialIndex: 1)
        XCTAssertEqual(viewModel.selectedWindowID, 2)

        manager.windows = [initial[0], initial[2]]
        viewModel.activateSelected()

        XCTAssertEqual(manager.activatedWindowIDs, [3])
        XCTAssertEqual(viewModel.selectedWindowID, 3)
    }

    private func makeViewModel(windows: [WindowModel], manager: SessionWindowManager) -> SwitchPanelViewModel {
        SwitchPanelViewModel(
            windows: windows,
            windowManager: manager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
    }

    private func makeWindow(id: CGWindowID, app: String, bundleID: String) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: bundleID,
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
}

private final class SessionWindowManager: WindowManagerProtocol, @unchecked Sendable {
    var windows: [WindowModel]
    var sequence: [CGWindowID: UInt64]
    var activatedWindowIDs: [CGWindowID] = []

    init(windows: [WindowModel], sequence: [CGWindowID: UInt64]) {
        self.windows = windows
        self.sequence = sequence
    }

    func getAllWindows(forceRefresh: Bool) -> [WindowModel] { windows }
    func activitySequenceSnapshot() -> [CGWindowID: UInt64] { sequence }
    func activateWindow(_ window: WindowModel) { activatedWindowIDs.append(window.id) }
    func closeWindow(_ window: WindowModel) {}
    func minimizeWindow(_ window: WindowModel) {}
    func hideWindow(_ window: WindowModel) {}
    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {}
    func refreshCache() {}
}
