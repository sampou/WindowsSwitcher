import AppKit
import Foundation
import XCTest
@testable import WindowsSwitcher

final class WindowLifecyclePollingTests: XCTestCase {
    func testStartSchedulesLowFrequencyEnumerationAndTickRunsIt() {
        let scheduler = ManualLifecycleScheduler()
        var enumerationCount = 0
        let poller = WindowLifecyclePoller(
            interval: 3.0,
            enumerateWindows: { enumerationCount += 1 },
            scheduler: scheduler.schedule
        )

        poller.start()

        XCTAssertEqual(scheduler.intervals, [3.0])
        XCTAssertEqual(enumerationCount, 0, "启动时不应立即扰动已有窗口顺序")

        scheduler.tokens[0].fire()
        XCTAssertEqual(enumerationCount, 1)
    }

    func testPauseSkipsEnumerationAndResumeRestoresIt() {
        let scheduler = ManualLifecycleScheduler()
        var enumerationCount = 0
        let poller = WindowLifecyclePoller(
            enumerateWindows: { enumerationCount += 1 },
            scheduler: scheduler.schedule
        )
        poller.start()

        poller.setPaused(true)
        scheduler.tokens[0].fire()
        XCTAssertEqual(enumerationCount, 0, "面板暂停期间不得枚举并改变窗口快照")

        poller.setPaused(false)
        scheduler.tokens[0].fire()
        XCTAssertEqual(enumerationCount, 1)
    }

    func testRestartReplacesOldTaskAndStopPreventsFutureEnumeration() {
        let scheduler = ManualLifecycleScheduler()
        var enumerationCount = 0
        let poller = WindowLifecyclePoller(
            enumerateWindows: { enumerationCount += 1 },
            scheduler: scheduler.schedule
        )

        poller.start()
        let firstToken = scheduler.tokens[0]
        poller.start()
        let secondToken = scheduler.tokens[1]

        XCTAssertTrue(firstToken.isInvalidated)
        firstToken.fire()
        XCTAssertEqual(enumerationCount, 0, "旧代次的回调即使迟到也必须被忽略")

        secondToken.fire()
        XCTAssertEqual(enumerationCount, 1)

        poller.stop()
        XCTAssertTrue(secondToken.isInvalidated)
        secondToken.fire()
        XCTAssertEqual(enumerationCount, 1, "停止返回后不得再开始枚举")
    }

    func testConcurrentTicksDoNotOverlapEnumeration() {
        let scheduler = ManualLifecycleScheduler()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "首个枚举结束")
        let countLock = NSLock()
        var enumerationCount = 0
        let poller = WindowLifecyclePoller(
            enumerateWindows: {
                countLock.lock()
                enumerationCount += 1
                countLock.unlock()
                entered.signal()
                release.wait()
            },
            scheduler: scheduler.schedule
        )
        poller.start()
        let token = scheduler.tokens[0]

        DispatchQueue.global().async {
            token.fire()
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        token.fire()
        countLock.lock()
        let observedCount = enumerationCount
        countLock.unlock()
        XCTAssertEqual(observedCount, 1, "前一次枚举未结束时应合并后续 tick")

        release.signal()
        wait(for: [finished], timeout: 1)
        poller.stop()
    }

    func testPollingSnapshotsProducesExternalCreateAndDestroyEvents() {
        let scheduler = ManualLifecycleScheduler()
        let first = makeWindow(id: 101)
        let second = makeWindow(id: 102)
        var snapshots = [[first], [first, second], [second]]
        var previous: [CGWindowID: WindowModel] = [:]
        var hasBaseline = false
        var createdWindowIDs: [CGWindowID] = []
        var destroyedWindowIDs: [CGWindowID] = []

        let poller = WindowLifecyclePoller(
            enumerateWindows: {
                let current = snapshots.removeFirst()
                let events = WindowSnapshotReconciler.events(
                    previous: previous,
                    current: current,
                    hasBaseline: hasBaseline
                )
                for event in events {
                    switch event {
                    case .windowCreated(let window):
                        createdWindowIDs.append(window.id)
                    case .windowDestroyed(let windowID):
                        destroyedWindowIDs.append(windowID)
                    case .windowStateChanged:
                        break
                    }
                }
                previous = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
                hasBaseline = true
            },
            scheduler: scheduler.schedule
        )
        poller.start()

        scheduler.tokens[0].fire() // 建立基线
        scheduler.tokens[0].fire() // 外部创建窗口
        scheduler.tokens[0].fire() // 外部销毁窗口

        XCTAssertEqual(createdWindowIDs, [102])
        XCTAssertEqual(destroyedWindowIDs, [101])
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
            lastActiveTime: .distantPast,
            windowLayer: 0,
            ownerPID: pid_t(id)
        )
    }
}

private final class ManualLifecycleScheduler {
    private(set) var intervals: [TimeInterval] = []
    private(set) var tokens: [ManualLifecycleToken] = []

    func schedule(interval: TimeInterval, tick: @escaping () -> Void) -> WindowLifecyclePollingToken {
        intervals.append(interval)
        let token = ManualLifecycleToken(tick: tick)
        tokens.append(token)
        return token
    }
}

private final class ManualLifecycleToken: WindowLifecyclePollingToken, @unchecked Sendable {
    private let tick: () -> Void
    private(set) var isInvalidated = false

    init(tick: @escaping () -> Void) {
        self.tick = tick
    }

    func invalidate() {
        isInvalidated = true
    }

    func fire() {
        tick()
    }
}
