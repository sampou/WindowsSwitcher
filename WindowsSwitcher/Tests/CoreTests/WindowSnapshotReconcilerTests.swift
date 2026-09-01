import AppKit
import XCTest
@testable import WindowsSwitcher

@MainActor
final class WindowSnapshotReconcilerTests: XCTestCase {
    func testCreatedWindowProducesCreatedEvent() {
        let existing = makeWindow(id: 1)
        let created = makeWindow(id: 2)

        let events = WindowSnapshotReconciler.events(
            previous: [existing.id: existing],
            current: [existing, created],
            hasBaseline: true
        )

        XCTAssertEqual(createdWindowIDs(in: events), [2])
        XCTAssertTrue(destroyedWindowIDs(in: events).isEmpty)
    }

    func testDestroyedWindowProducesDestroyedEvent() {
        let destroyed = makeWindow(id: 3)
        let remaining = makeWindow(id: 4)

        let events = WindowSnapshotReconciler.events(
            previous: [destroyed.id: destroyed, remaining.id: remaining],
            current: [remaining],
            hasBaseline: true
        )

        XCTAssertTrue(createdWindowIDs(in: events).isEmpty)
        XCTAssertEqual(destroyedWindowIDs(in: events), [3])
    }

    func testUnchangedSnapshotProducesNoEvents() {
        let first = makeWindow(id: 5)
        let second = makeWindow(id: 6)

        let events = WindowSnapshotReconciler.events(
            previous: [first.id: first, second.id: second],
            current: [first, second],
            hasBaseline: true
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testDestroyedEventRefreshPrunesFrozenSameAppSession() {
        let initial = [makeWindow(id: 7), makeWindow(id: 8), makeWindow(id: 9)]
        let manager = SnapshotEventWindowManager(windows: initial)
        let viewModel = SwitchPanelViewModel(
            windows: initial,
            windowManager: manager,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
        viewModel.beginSameAppSwitchSession(
            bundleIdentifier: "com.example.editor",
            initialIndex: 1
        )

        let current = [initial[1], initial[2]]
        let previous = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
        let events = WindowSnapshotReconciler.events(
            previous: previous,
            current: current,
            hasBaseline: true
        )
        manager.windows = current

        for event in events {
            if case .windowDestroyed = event {
                viewModel.refreshWindows()
            }
        }

        XCTAssertEqual(destroyedWindowIDs(in: events), [7])
        XCTAssertEqual(Set(viewModel.sameAppSwitchSession?.windowIDs ?? []), Set([8, 9]))
        XCTAssertEqual(Set(viewModel.filteredWindows.map(\.id)), Set([8, 9]))
        XCTAssertFalse(viewModel.filteredWindows.map(\.id).contains(7))
    }

    func testFirstSuccessfulEnumerationOnlyEstablishesBaseline() {
        let alreadyOpen = makeWindow(id: 10)

        let events = WindowSnapshotReconciler.events(
            previous: [:],
            current: [alreadyOpen],
            hasBaseline: false
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testCreatedWindowAfterEstablishedEmptyBaselineProducesEvent() {
        let created = makeWindow(id: 11)

        let events = WindowSnapshotReconciler.events(
            previous: [:],
            current: [created],
            hasBaseline: true
        )

        XCTAssertEqual(createdWindowIDs(in: events), [11])
        XCTAssertTrue(destroyedWindowIDs(in: events).isEmpty)
    }

    private func createdWindowIDs(in events: [WindowEvent]) -> [CGWindowID] {
        events.compactMap { event in
            guard case .windowCreated(let window) = event else { return nil }
            return window.id
        }
    }

    private func destroyedWindowIDs(in events: [WindowEvent]) -> [CGWindowID] {
        events.compactMap { event in
            guard case .windowDestroyed(let windowID) = event else { return nil }
            return windowID
        }
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
}

private final class SnapshotEventWindowManager: WindowManagerProtocol, @unchecked Sendable {
    var windows: [WindowModel]

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
