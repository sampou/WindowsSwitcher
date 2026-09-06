import CoreGraphics
import XCTest
@testable import WindowsSwitcher

final class WindowLayoutCalculatorTests: XCTestCase {
    private let calculator = WindowLayoutCalculator()

    func testHalfLayoutsShareBoundaryWithoutGapForOddVisibleSize() {
        let visible = CGRect(x: -100, y: 50, width: 1_001, height: 801)
        let current = CGRect(x: 0, y: 0, width: 320, height: 240)

        let left = calculator.targetFrame(for: .leftHalf, currentFrame: current, visibleFrame: visible)
        let right = calculator.targetFrame(for: .rightHalf, currentFrame: current, visibleFrame: visible)
        let top = calculator.targetFrame(for: .topHalf, currentFrame: current, visibleFrame: visible)
        let bottom = calculator.targetFrame(for: .bottomHalf, currentFrame: current, visibleFrame: visible)

        XCTAssertEqual(left, CGRect(x: -100, y: 50, width: 500, height: 801))
        XCTAssertEqual(right, CGRect(x: 400, y: 50, width: 501, height: 801))
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.union(right), visible)

        XCTAssertEqual(top, CGRect(x: -100, y: 50, width: 1_001, height: 400))
        XCTAssertEqual(bottom, CGRect(x: -100, y: 450, width: 1_001, height: 401))
        XCTAssertEqual(top.maxY, bottom.minY)
        XCTAssertEqual(top.union(bottom), visible)
    }

    func testQuarterLayoutsExactlyCoverVisibleFrame() {
        let visible = CGRect(x: -1_601, y: -900, width: 1_601, height: 901)
        let current = CGRect(x: -1_400, y: -700, width: 400, height: 300)
        let commands: [WindowLayoutCommand] = [
            .topLeftQuarter,
            .topRightQuarter,
            .bottomLeftQuarter,
            .bottomRightQuarter
        ]

        let frames = commands.map {
            calculator.targetFrame(for: $0, currentFrame: current, visibleFrame: visible)
        }

        XCTAssertTrue(frames.allSatisfy { visible.contains($0) })
        XCTAssertEqual(frames.reduce(CGRect.null) { $0.union($1) }, visible)
        XCTAssertEqual(frames[0].maxX, frames[1].minX)
        XCTAssertEqual(frames[0].maxY, frames[2].minY)
    }

    func testMaximizeUsesVisibleFrameInsteadOfFullScreenFrame() {
        let visible = CGRect(x: 0, y: 25, width: 1_920, height: 1_015)

        let target = calculator.targetFrame(
            for: .maximize,
            currentFrame: CGRect(x: 10, y: 10, width: 800, height: 600),
            visibleFrame: visible
        )

        XCTAssertEqual(target, visible)
    }

    func testCenterPreservesSizeAndClampsOversizedWindow() {
        let visible = CGRect(x: 100, y: 200, width: 1_000, height: 700)
        let normal = calculator.targetFrame(
            for: .center,
            currentFrame: CGRect(x: -500, y: -500, width: 400, height: 200),
            visibleFrame: visible
        )
        let oversized = calculator.targetFrame(
            for: .center,
            currentFrame: CGRect(x: 0, y: 0, width: 2_000, height: 1_000),
            visibleFrame: visible
        )

        XCTAssertEqual(normal, CGRect(x: 400, y: 450, width: 400, height: 200))
        XCTAssertEqual(oversized, visible)
    }

    func testDisplayMovePreservesRelativeCenterAndLogicalSize() {
        let source = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let target = CGRect(x: -1_600, y: 100, width: 1_600, height: 900)
        let current = CGRect(x: 100, y: 80, width: 400, height: 200)

        let moved = calculator.targetFrameForDisplayMove(
            currentFrame: current,
            sourceVisibleFrame: source,
            targetVisibleFrame: target
        )

        XCTAssertEqual(moved, CGRect(x: -1_320, y: 203, width: 400, height: 200))
        XCTAssertTrue(target.contains(moved))
    }

    func testDisplayMoveProportionallyShrinksOversizedWindow() {
        let moved = calculator.targetFrameForDisplayMove(
            currentFrame: CGRect(x: 0, y: 0, width: 2_000, height: 1_000),
            sourceVisibleFrame: CGRect(x: 0, y: 0, width: 2_000, height: 1_000),
            targetVisibleFrame: CGRect(x: 2_000, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(moved.size, CGSize(width: 800, height: 400))
        XCTAssertEqual(moved, CGRect(x: 2_000, y: 100, width: 800, height: 400))
    }

    func testInvalidVisibleFrameReturnsZero() {
        XCTAssertEqual(
            calculator.targetFrame(
                for: .leftHalf,
                currentFrame: CGRect(x: 1, y: 1, width: 10, height: 10),
                visibleFrame: .zero
            ),
            .zero
        )
    }
}
