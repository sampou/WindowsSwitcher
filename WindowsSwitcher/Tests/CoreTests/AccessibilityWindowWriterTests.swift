import AppKit
import ApplicationServices
import XCTest
@testable import WindowsSwitcher

final class AccessibilityWindowWriterTests: XCTestCase {
    func testProductionFallbackRequiresMatchingFrameAndNonEmptyTitle() {
        let modelFrame = CGRect(x: 100, y: 120, width: 500, height: 400)

        XCTAssertTrue(SystemAccessibilityWindowBackend.matchesFallback(
            modelFrame: modelFrame,
            modelTitle: "测试窗口",
            candidateFrame: modelFrame.offsetBy(dx: 4, dy: -4),
            candidateTitle: "测试窗口"
        ))
        XCTAssertFalse(SystemAccessibilityWindowBackend.matchesFallback(
            modelFrame: modelFrame,
            modelTitle: "",
            candidateFrame: modelFrame,
            candidateTitle: ""
        ))
        XCTAssertFalse(SystemAccessibilityWindowBackend.matchesFallback(
            modelFrame: modelFrame,
            modelTitle: "测试窗口",
            candidateFrame: modelFrame,
            candidateTitle: "其他窗口"
        ))
        XCTAssertFalse(SystemAccessibilityWindowBackend.matchesFallback(
            modelFrame: modelFrame,
            modelTitle: "测试窗口",
            candidateFrame: modelFrame.offsetBy(dx: 6, dy: 0),
            candidateTitle: "测试窗口"
        ))
    }

    func testProbeReturnsCurrentFrameAndWritableCapabilities() {
        let backend = MockAccessibilityWindowBackend()
        let writer = AccessibilityWindowWriter(backend: backend)

        let result = writer.probe(makeWindow())

        guard case .success(let capabilities) = result else {
            return XCTFail("标准可写窗口应通过能力探测")
        }
        XCTAssertEqual(capabilities.currentFrame, backend.currentFrame)
        XCTAssertFalse(capabilities.isFullScreen)
        XCTAssertTrue(capabilities.canSetPosition)
        XCTAssertTrue(capabilities.canSetSize)
    }

    func testPermissionFailureStopsBeforeResolvingWindow() {
        let backend = MockAccessibilityWindowBackend()
        backend.trusted = false

        assertProbeFailure(.accessibilityPermissionMissing, backend: backend)
        XCTAssertEqual(backend.resolveCount, 0)
    }

    func testMissingAndNonStandardWindowsReturnSpecificFailures() {
        let missingBackend = MockAccessibilityWindowBackend()
        missingBackend.resolvesWindow = false
        assertProbeFailure(.windowNotFound, backend: missingBackend)

        let modelBackend = MockAccessibilityWindowBackend()
        assertProbeFailure(.nonStandardWindow, backend: modelBackend, model: makeWindow(isStandardWindow: false))
        XCTAssertEqual(modelBackend.resolveCount, 0)

        let elementBackend = MockAccessibilityWindowBackend()
        elementBackend.standardWindow = false
        assertProbeFailure(.nonStandardWindow, backend: elementBackend)
    }

    func testFullScreenWindowIsSkippedWithoutWriting() {
        let backend = MockAccessibilityWindowBackend()
        backend.fullScreen = true
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .skipped(.fullScreenWindow)
        )
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testNonWritableAttributesReturnSpecificFailures() {
        let positionBackend = MockAccessibilityWindowBackend()
        positionBackend.positionSettable = false
        assertProbeFailure(.positionNotWritable, backend: positionBackend)

        let sizeBackend = MockAccessibilityWindowBackend()
        sizeBackend.sizeSettable = false
        assertProbeFailure(.sizeNotWritable, backend: sizeBackend)
    }

    func testApplyWritesPositionSizePositionAndVerifiesExactFrame() {
        let backend = MockAccessibilityWindowBackend()
        let original = backend.currentFrame
        let writer = AccessibilityWindowWriter(backend: backend)

        let result = writer.apply(targetFrame: targetFrame, to: makeWindow())

        XCTAssertEqual(
            result,
            .applied(originalFrame: original, actualFrame: targetFrame)
        )
        XCTAssertEqual(backend.operations, [
            "position:0.0,25.0",
            "size:960.0,1015.0",
            "position:0.0,25.0"
        ])
    }

    func testReadbackWithinToleranceIsApplied() {
        let backend = MockAccessibilityWindowBackend()
        let original = backend.currentFrame
        let adjusted = CGRect(x: 1, y: 24, width: 959, height: 1_016)
        backend.frameReads = [original, adjusted]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .applied(originalFrame: original, actualFrame: adjusted)
        )
    }

    func testApplicationMinimumSizeAdjustmentIsReportedAsConstrained() {
        let backend = MockAccessibilityWindowBackend()
        let original = backend.currentFrame
        let adjusted = CGRect(x: 4, y: 30, width: 1_100, height: 1_015)
        backend.frameReads = [original, adjusted]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .constrained(originalFrame: original, actualFrame: adjusted)
        )
    }

    func testDistantReadbackReturnsVerificationFailure() {
        let backend = MockAccessibilityWindowBackend()
        backend.frameReads = [backend.currentFrame, CGRect(x: 300, y: 300, width: 200, height: 200)]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .skipped(.verificationFailed)
        )
    }

    func testInvalidTargetFrameDoesNotWrite() {
        let backend = MockAccessibilityWindowBackend()
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: CGRect(x: 0, y: 0, width: 0, height: 100), to: makeWindow()),
            .skipped(.verificationFailed)
        )
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testFirstPositionFailureStopsSubsequentWrites() {
        let backend = MockAccessibilityWindowBackend()
        backend.positionResults = [.cannotComplete]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .skipped(.writeFailed(code: Int(AXError.cannotComplete.rawValue)))
        )
        XCTAssertEqual(backend.operations, ["position:0.0,25.0"])
    }

    func testSizeFailureRestoresOriginalPosition() {
        let backend = MockAccessibilityWindowBackend()
        let original = backend.currentFrame
        backend.sizeResults = [.attributeUnsupported]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .skipped(.writeFailed(code: Int(AXError.attributeUnsupported.rawValue)))
        )
        XCTAssertEqual(backend.currentFrame.origin, original.origin)
        XCTAssertEqual(backend.operations, [
            "position:0.0,25.0",
            "size:960.0,1015.0",
            "position:100.0,120.0"
        ])
    }

    func testSecondPositionFailureRollsBackOriginalFrame() {
        let backend = MockAccessibilityWindowBackend()
        let original = backend.currentFrame
        backend.positionResults = [.success, .cannotComplete, .success]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .skipped(.writeFailed(code: Int(AXError.cannotComplete.rawValue)))
        )
        XCTAssertEqual(backend.currentFrame, original)
        XCTAssertEqual(backend.operations.suffix(2), [
            "size:500.0,400.0",
            "position:100.0,120.0"
        ])
    }

    func testDestroyedWindowDuringWriteMapsToWindowNotFound() {
        let backend = MockAccessibilityWindowBackend()
        backend.positionResults = [.invalidUIElement]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .skipped(.windowNotFound)
        )
    }

    func testMissingReadbackReturnsVerificationFailure() {
        let backend = MockAccessibilityWindowBackend()
        backend.frameReads = [backend.currentFrame, nil]
        let writer = AccessibilityWindowWriter(backend: backend)

        XCTAssertEqual(
            writer.apply(targetFrame: targetFrame, to: makeWindow()),
            .skipped(.verificationFailed)
        )
    }

    private let targetFrame = CGRect(x: 0, y: 25, width: 960, height: 1_015)

    private func assertProbeFailure(
        _ expected: WindowLayoutFailure,
        backend: MockAccessibilityWindowBackend,
        model: WindowModel? = nil
    ) {
        let writer = AccessibilityWindowWriter(backend: backend)
        guard case .failure(let failure) = writer.probe(model ?? makeWindow()) else {
            return XCTFail("能力探测应失败：\(expected)")
        }
        XCTAssertEqual(failure, expected)
    }

    private func makeWindow(isStandardWindow: Bool = true) -> WindowModel {
        WindowModel(
            id: 42,
            appName: "测试应用",
            bundleIdentifier: "com.example.test",
            windowTitle: "测试窗口",
            appIcon: NSImage(),
            frame: CGRect(x: 100, y: 120, width: 500, height: 400),
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: .distantPast,
            windowLayer: 0,
            ownerPID: 123,
            isStandardWindow: isStandardWindow
        )
    }
}

private final class MockAccessibilityWindowBackend: AccessibilityWindowAccessing {
    let reference = AccessibilityWindowReference()
    var trusted = true
    var resolvesWindow = true
    var standardWindow = true
    var fullScreen = false
    var positionSettable = true
    var sizeSettable = true
    var currentFrame = CGRect(x: 100, y: 120, width: 500, height: 400)
    var frameReads: [CGRect?] = []
    var positionResults: [AXError] = []
    var sizeResults: [AXError] = []
    var operations: [String] = []
    var resolveCount = 0

    func isProcessTrusted() -> Bool {
        trusted
    }

    func resolveWindow(for model: WindowModel) -> AccessibilityWindowReference? {
        resolveCount += 1
        return resolvesWindow ? reference : nil
    }

    func isStandardWindow(_ window: AccessibilityWindowReference) -> Bool {
        standardWindow
    }

    func isFullScreen(_ window: AccessibilityWindowReference) -> Bool {
        fullScreen
    }

    func isSettable(
        _ attribute: AccessibilityWritableAttribute,
        for window: AccessibilityWindowReference
    ) -> Bool {
        switch attribute {
        case .position:
            return positionSettable
        case .size:
            return sizeSettable
        }
    }

    func frame(of window: AccessibilityWindowReference) -> CGRect? {
        if !frameReads.isEmpty {
            return frameReads.removeFirst()
        }
        return currentFrame
    }

    func setPosition(_ position: CGPoint, for window: AccessibilityWindowReference) -> AXError {
        operations.append("position:\(position.x),\(position.y)")
        let result = positionResults.isEmpty ? AXError.success : positionResults.removeFirst()
        if result == .success {
            currentFrame.origin = position
        }
        return result
    }

    func setSize(_ size: CGSize, for window: AccessibilityWindowReference) -> AXError {
        operations.append("size:\(size.width),\(size.height)")
        let result = sizeResults.isEmpty ? AXError.success : sizeResults.removeFirst()
        if result == .success {
            currentFrame.size = size
        }
        return result
    }
}
