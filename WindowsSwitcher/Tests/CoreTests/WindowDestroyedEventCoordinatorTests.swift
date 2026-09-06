import XCTest
@testable import WindowsSwitcher

final class WindowDestroyedEventCoordinatorTests: XCTestCase {
    @MainActor
    func testHandleRefreshesWindowsAndInvalidatesDestroyedWindowPreview() async {
        let invalidator = PreviewCacheInvalidatorSpy()
        let coordinator = WindowDestroyedEventCoordinator(previewCacheInvalidator: invalidator)
        var refreshCount = 0

        let cleanupTask = coordinator.handle(windowID: 42) {
            refreshCount += 1
        }

        XCTAssertEqual(refreshCount, 1, "窗口列表应在销毁事件到达时立即刷新")
        await cleanupTask.value

        let invalidatedWindowIDs = await invalidator.invalidatedWindowIDs
        XCTAssertEqual(invalidatedWindowIDs, [42], "应异步清理被销毁窗口的预览缓存")
    }

    @MainActor
    func testHandleInvalidatesEachDestroyedWindowExactlyOnce() async {
        let invalidator = PreviewCacheInvalidatorSpy()
        let coordinator = WindowDestroyedEventCoordinator(previewCacheInvalidator: invalidator)

        let firstCleanup = coordinator.handle(windowID: 7, refreshWindows: {})
        let secondCleanup = coordinator.handle(windowID: 9, refreshWindows: {})
        await firstCleanup.value
        await secondCleanup.value

        let invalidatedWindowIDs = await invalidator.invalidatedWindowIDs.sorted()
        XCTAssertEqual(invalidatedWindowIDs, [7, 9])
    }
}

private actor PreviewCacheInvalidatorSpy: PreviewCacheInvalidating {
    private(set) var invalidatedWindowIDs: [CGWindowID] = []

    func invalidateCache(for windowID: CGWindowID) async {
        invalidatedWindowIDs.append(windowID)
    }
}
