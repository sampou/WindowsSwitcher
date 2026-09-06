import XCTest
@testable import WindowsSwitcher

final class WindowOrderingTests: XCTestCase {
    private let ordering = WindowOrdering()
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testRecentUsesActivitySequenceBeforeTimestamp() {
        let older = makeWindow(id: 10, app: "A", title: "Older", time: fixedDate.addingTimeInterval(-100))
        let newer = makeWindow(id: 20, app: "B", title: "Newer", time: fixedDate)

        let result = ordering.sort([newer, older], by: .recent, activitySequence: [10: 2, 20: 1])

        XCTAssertEqual(result.map(\.id), [10, 20])
    }

    func testRecentFallsBackToTimestampThenDescendingWindowID() {
        let lowerID = makeWindow(id: 10, app: "A", title: "One", time: fixedDate)
        let higherID = makeWindow(id: 20, app: "A", title: "Two", time: fixedDate)

        let result = ordering.sort([lowerID, higherID], by: .recent)

        XCTAssertEqual(result.map(\.id), [20, 10])
    }

    func testAllSortOrdersAreDeterministic() {
        let windows = [
            makeWindow(id: 1, app: "Safari", title: "Beta", time: fixedDate),
            makeWindow(id: 3, app: "Safari", title: "Alpha", time: fixedDate),
            makeWindow(id: 2, app: "Chrome", title: "Alpha", time: fixedDate)
        ]

        for order in SortOrder.allCases {
            let expected: [CGWindowID]
            switch order {
            case .recent: expected = [3, 2, 1]
            case .appName: expected = [2, 3, 1]
            case .windowTitle: expected = [2, 3, 1]
            case .appGroup: expected = [3, 1, 2]
            }
            for _ in 0..<100 {
                XCTAssertEqual(ordering.sort(windows, by: order).map(\.id), expected)
            }
        }
        XCTAssertEqual(windows.map(\.id), [1, 3, 2], "排序不得修改输入数组")
    }

    func testAppGroupUsesMaximumActivitySequenceAndKeepsGroupsContiguous() {
        let windows = [
            makeWindow(id: 1, app: "Safari", title: "First", time: fixedDate),
            makeWindow(id: 2, app: "Chrome", title: "First", time: fixedDate),
            makeWindow(id: 3, app: "Safari", title: "Second", time: fixedDate)
        ]

        let result = ordering.sort(
            windows,
            by: .appGroup,
            activitySequence: [1: 1, 2: 2, 3: 3]
        )

        XCTAssertEqual(result.map(\.id), [3, 1, 2])
    }

    func testAppGroupKeepsTargetApplicationFirst() {
        let targetOld = makeWindow(id: 1, app: "Safari", title: "Old", time: fixedDate.addingTimeInterval(-10))
        let otherNew = makeWindow(id: 2, app: "Chrome", title: "New", time: fixedDate)
        let targetNew = makeWindow(id: 3, app: "Safari", title: "New", time: fixedDate)

        let result = ordering.sortByAppGroup(
            [targetOld, otherNew, targetNew],
            targetAppBundleID: targetNew.bundleIdentifier
        )

        XCTAssertEqual(result.map(\.id), [3, 1, 2])
    }

    private func makeWindow(
        id: CGWindowID,
        app: String,
        title: String,
        time: Date
    ) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: "com.example.\(app.lowercased())",
            windowTitle: title,
            appIcon: NSImage(),
            frame: .zero,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: time,
            windowLayer: 0,
            ownerPID: pid_t(id)
        )
    }
}
