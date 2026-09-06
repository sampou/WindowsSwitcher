import XCTest
@testable import WindowsSwitcher

final class WindowActivitySequenceTests: XCTestCase {
    func testFirstObservationDoesNotAdvanceTwice() {
        let sequence = WindowActivitySequence()

        XCTAssertTrue(sequence.recordFirstObservation(windowID: 7))
        XCTAssertFalse(sequence.recordFirstObservation(windowID: 7))

        XCTAssertEqual(sequence.snapshot(), [7: 1])
        XCTAssertEqual(sequence.revision, 1)
    }

    func testRecordAdvancesExistingWindowAndCleanupRemovesOnlyRequestedIDs() {
        let sequence = WindowActivitySequence()
        sequence.recordFirstObservation(windowID: 7)
        sequence.recordFirstObservation(windowID: 9)

        XCTAssertEqual(sequence.record(windowID: 7), 3)
        XCTAssertTrue(sequence.remove(windowIDs: [7, 99]))
        XCTAssertEqual(sequence.snapshot(), [9: 2])
        XCTAssertEqual(sequence.revision, 4)
        XCTAssertFalse(sequence.remove(windowIDs: [99]))
        XCTAssertEqual(sequence.revision, 4)
    }

    func testConcurrentRecordsRemainUniqueAndMonotonic() {
        let sequence = WindowActivitySequence()

        DispatchQueue.concurrentPerform(iterations: 1_000) { iteration in
            sequence.record(windowID: CGWindowID(iteration % 10))
        }

        let snapshot = sequence.snapshot()
        XCTAssertEqual(snapshot.count, 10)
        XCTAssertEqual(Set(snapshot.values).count, 10)
        XCTAssertEqual(snapshot.values.max(), 1_000)
        XCTAssertEqual(sequence.revision, 1_000)
    }

    func testProtocolDefaultSnapshotIsEmptyForCompatibilityDouble() {
        let manager = DefaultActivitySnapshotWindowManager()

        XCTAssertEqual(manager.activitySequenceSnapshot(), [:])
    }

    func testProductionSnapshotMutationDoesNotWriteBackToManager() {
        let manager = WindowManager.shared
        let sentinelID = CGWindowID.max
        let originalValue = manager.activitySequenceSnapshot()[sentinelID]

        var detachedSnapshot = manager.activitySequenceSnapshot()
        detachedSnapshot[sentinelID] = (originalValue ?? 0) &+ 1

        XCTAssertEqual(manager.activitySequenceSnapshot()[sentinelID], originalValue)
    }

    func testProductionSnapshotSupportsConcurrentReadsAndDetachedMutations() {
        let manager = WindowManager.shared
        let baseline = manager.activitySequenceSnapshot()
        let mismatches = LockedMismatchCounter()

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            var localSnapshot = manager.activitySequenceSnapshot()
            localSnapshot[CGWindowID(iteration)] = UInt64(iteration)
            let currentSnapshot = manager.activitySequenceSnapshot()

            if currentSnapshot != baseline {
                mismatches.increment()
            }
        }

        XCTAssertEqual(mismatches.value, 0)
        XCTAssertEqual(manager.activitySequenceSnapshot(), baseline)
    }
}

private final class DefaultActivitySnapshotWindowManager: WindowManagerProtocol {
    func getAllWindows(forceRefresh: Bool) -> [WindowModel] { [] }
    func activateWindow(_ window: WindowModel) {}
    func closeWindow(_ window: WindowModel) {}
    func minimizeWindow(_ window: WindowModel) {}
    func hideWindow(_ window: WindowModel) {}
    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {}
    func refreshCache() {}
}

private final class LockedMismatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
