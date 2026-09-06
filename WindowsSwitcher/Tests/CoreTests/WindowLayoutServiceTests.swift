import AppKit
import CoreGraphics
import XCTest
@testable import WindowsSwitcher

final class WindowLayoutServiceTests: XCTestCase {
    func testSingleScreenCommandUsesCurrentScreenAndWritesCalculatedFrame() {
        let writer = MockWindowLayoutWriter()
        let resolver = MockScreenResolver(current: sourceScreen)
        let logger = MockWindowLayoutLogger()
        let service = makeService(writer: writer, resolver: resolver, logger: logger)

        let result = service.execute(.leftHalf, for: window)

        let expected = CGRect(x: 0, y: 25, width: 960, height: 1_015)
        XCTAssertEqual(writer.appliedFrames, [expected])
        XCTAssertEqual(result, .applied(frame: expected, displayID: sourceScreen.id))
        XCTAssertEqual(logger.records.last?.result, result)
    }

    func testProbeFailureStopsBeforeScreenResolutionAndWrite() {
        let writer = MockWindowLayoutWriter()
        writer.probeResult = .failure(.accessibilityPermissionMissing)
        var resolverCreationCount = 0
        let logger = MockWindowLayoutLogger()
        let service = WindowLayoutService(
            writer: writer,
            screenResolverProvider: {
                resolverCreationCount += 1
                return MockScreenResolver(current: self.sourceScreen)
            },
            logger: logger
        )

        XCTAssertEqual(
            service.execute(.maximize, for: window),
            .skipped(.accessibilityPermissionMissing)
        )
        XCTAssertEqual(resolverCreationCount, 0)
        XCTAssertTrue(writer.appliedFrames.isEmpty)
    }

    func testMissingCurrentScreenReturnsTargetDisplayUnavailable() {
        let writer = MockWindowLayoutWriter()
        let service = makeService(writer: writer, resolver: MockScreenResolver(current: nil))

        XCTAssertEqual(
            service.execute(.rightHalf, for: window),
            .skipped(.targetDisplayUnavailable)
        )
        XCTAssertTrue(writer.appliedFrames.isEmpty)
    }

    func testAdjacentDisplayCommandMovesRelativeFrameAndUsesTargetDisplayID() {
        let writer = MockWindowLayoutWriter()
        writer.probeResult = .success(capabilities(frame: CGRect(x: 480, y: 250, width: 640, height: 480)))
        let resolver = MockScreenResolver(current: sourceScreen, adjacent: targetScreen)
        let service = makeService(writer: writer, resolver: resolver)

        let result = service.execute(.nextDisplay, for: window)

        guard let target = writer.appliedFrames.first else {
            return XCTFail("跨屏命令应写入目标 frame")
        }
        XCTAssertEqual(target.size, CGSize(width: 640, height: 480))
        XCTAssertTrue(targetScreen.visibleFrame.contains(target))
        XCTAssertEqual(result, .applied(frame: target, displayID: targetScreen.id))
        XCTAssertEqual(resolver.adjacentRequests, [.next])
    }

    func testPreviousDisplayUsesPreviousDirection() {
        let writer = MockWindowLayoutWriter()
        let resolver = MockScreenResolver(current: sourceScreen, adjacent: targetScreen)
        let service = makeService(writer: writer, resolver: resolver)

        _ = service.execute(.previousDisplay, for: window)

        XCTAssertEqual(resolver.adjacentRequests, [.previous])
    }

    func testSingleDisplayRejectsDisplayMoveWithoutWriting() {
        let writer = MockWindowLayoutWriter()
        let resolver = MockScreenResolver(current: sourceScreen, adjacent: nil)
        let service = makeService(writer: writer, resolver: resolver)

        XCTAssertEqual(
            service.execute(.nextDisplay, for: window),
            .skipped(.targetDisplayUnavailable)
        )
        XCTAssertTrue(writer.appliedFrames.isEmpty)
    }

    func testConstrainedWriterResultIsPreservedForUIFeedback() {
        let writer = MockWindowLayoutWriter()
        let actual = CGRect(x: 4, y: 30, width: 1_100, height: 1_015)
        writer.writeResult = .constrained(originalFrame: currentFrame, actualFrame: actual)
        let service = makeService(writer: writer, resolver: MockScreenResolver(current: sourceScreen))

        XCTAssertEqual(
            service.execute(.leftHalf, for: window),
            .constrained(frame: actual, displayID: sourceScreen.id)
        )
    }

    func testWriterFailureIsPropagatedWithoutAffectingNextCommand() {
        let writer = MockWindowLayoutWriter()
        writer.writeResults = [
            .skipped(.writeFailed(code: 42)),
            .applied(originalFrame: currentFrame, actualFrame: sourceScreen.visibleFrame)
        ]
        let service = makeService(writer: writer, resolver: MockScreenResolver(current: sourceScreen))

        XCTAssertEqual(
            service.execute(.leftHalf, for: window),
            .skipped(.writeFailed(code: 42))
        )
        XCTAssertEqual(
            service.execute(.maximize, for: window),
            .applied(frame: sourceScreen.visibleFrame, displayID: sourceScreen.id)
        )
    }

    func testRepeatedCommandReturnsAppliedWithoutSecondAXWrite() {
        let repeatedFrame = CGRect(x: 0, y: 25, width: 960, height: 1_015)
        let writer = MockWindowLayoutWriter()
        writer.probeResult = .success(capabilities(frame: repeatedFrame))
        let logger = MockWindowLayoutLogger()
        let service = makeService(
            writer: writer,
            resolver: MockScreenResolver(current: sourceScreen),
            logger: logger
        )

        XCTAssertEqual(
            service.execute(.leftHalf, for: window),
            .applied(frame: repeatedFrame, displayID: sourceScreen.id)
        )
        XCTAssertTrue(writer.appliedFrames.isEmpty)
        XCTAssertTrue(logger.records.last?.repeated == true)
    }

    private let currentFrame = CGRect(x: 100, y: 120, width: 500, height: 400)
    private let sourceScreen = ScreenDescriptor(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        visibleFrame: CGRect(x: 0, y: 25, width: 1_920, height: 1_015),
        isMain: true
    )
    private let targetScreen = ScreenDescriptor(
        id: 2,
        frame: CGRect(x: 1_920, y: 0, width: 1_440, height: 900),
        visibleFrame: CGRect(x: 1_920, y: 25, width: 1_440, height: 875),
        isMain: false
    )

    private var window: WindowModel {
        WindowModel(
            id: 42,
            appName: "测试应用",
            bundleIdentifier: "com.example.layout",
            windowTitle: "测试窗口",
            appIcon: NSImage(),
            frame: currentFrame,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: .distantPast,
            windowLayer: 0,
            ownerPID: 123,
            isStandardWindow: true
        )
    }

    private func capabilities(frame: CGRect) -> AccessibilityWindowCapabilities {
        AccessibilityWindowCapabilities(
            currentFrame: frame,
            isFullScreen: false,
            canSetPosition: true,
            canSetSize: true
        )
    }

    private func makeService(
        writer: MockWindowLayoutWriter,
        resolver: MockScreenResolver,
        logger: MockWindowLayoutLogger = MockWindowLayoutLogger()
    ) -> WindowLayoutService {
        WindowLayoutService(
            writer: writer,
            screenResolverProvider: { resolver },
            logger: logger
        )
    }
}

private final class MockWindowLayoutWriter: AccessibilityWindowWriting {
    var probeResult: Result<AccessibilityWindowCapabilities, WindowLayoutFailure> = .success(
        AccessibilityWindowCapabilities(
            currentFrame: CGRect(x: 100, y: 120, width: 500, height: 400),
            isFullScreen: false,
            canSetPosition: true,
            canSetSize: true
        )
    )
    var writeResult: AccessibilityWindowWriteResult?
    var writeResults: [AccessibilityWindowWriteResult] = []
    var appliedFrames: [CGRect] = []

    func probe(_ model: WindowModel) -> Result<AccessibilityWindowCapabilities, WindowLayoutFailure> {
        probeResult
    }

    func apply(targetFrame: CGRect, to model: WindowModel) -> AccessibilityWindowWriteResult {
        appliedFrames.append(targetFrame)
        if !writeResults.isEmpty {
            return writeResults.removeFirst()
        }
        return writeResult ?? .applied(originalFrame: model.frame, actualFrame: targetFrame)
    }
}

private final class MockScreenResolver: ScreenResolving {
    let current: ScreenDescriptor?
    let adjacent: ScreenDescriptor?
    var adjacentRequests: [DisplayTraversalDirection] = []

    init(current: ScreenDescriptor?, adjacent: ScreenDescriptor? = nil) {
        self.current = current
        self.adjacent = adjacent
    }

    func currentScreen(for windowFrame: CGRect) -> ScreenDescriptor? {
        current
    }

    func adjacentScreen(
        from displayID: CGDirectDisplayID,
        direction: DisplayTraversalDirection
    ) -> ScreenDescriptor? {
        adjacentRequests.append(direction)
        return adjacent
    }
}

private final class MockWindowLayoutLogger: WindowLayoutLogging {
    struct Record {
        let command: WindowLayoutCommand
        let windowID: CGWindowID
        let result: WindowLayoutResult
        let repeated: Bool
    }

    var records: [Record] = []

    func record(
        command: WindowLayoutCommand,
        windowID: CGWindowID,
        result: WindowLayoutResult,
        repeated: Bool
    ) {
        records.append(Record(
            command: command,
            windowID: windowID,
            result: result,
            repeated: repeated
        ))
    }
}
