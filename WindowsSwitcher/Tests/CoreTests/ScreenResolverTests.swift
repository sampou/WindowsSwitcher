import CoreGraphics
import XCTest
@testable import WindowsSwitcher

final class ScreenResolverTests: XCTestCase {
    func testCurrentScreenPrefersWindowCenter() {
        let left = screen(id: 1, frame: CGRect(x: -1_000, y: 0, width: 1_000, height: 800))
        let main = screen(id: 2, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), isMain: true)
        let resolver = ScreenResolver(screens: [main, left])

        let resolved = resolver.currentScreen(
            for: CGRect(x: -600, y: 100, width: 900, height: 500)
        )

        XCTAssertEqual(resolved?.id, left.id)
    }

    func testCurrentScreenUsesLargestIntersectionWhenCenterIsInGap() {
        let left = screen(id: 1, frame: CGRect(x: 0, y: 0, width: 900, height: 800), isMain: true)
        let right = screen(id: 2, frame: CGRect(x: 1_100, y: 0, width: 1_000, height: 800))
        let resolver = ScreenResolver(screens: [right, left])

        let resolved = resolver.currentScreen(
            for: CGRect(x: 800, y: 100, width: 500, height: 500)
        )

        XCTAssertEqual(resolved?.id, right.id)
    }

    func testCurrentScreenFallsBackToMainScreen() {
        let main = screen(id: 10, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), isMain: true)
        let other = screen(id: 20, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800))
        let resolver = ScreenResolver(screens: [other, main])

        XCTAssertEqual(
            resolver.currentScreen(for: CGRect(x: 5_000, y: 5_000, width: 100, height: 100))?.id,
            main.id
        )
    }

    func testAdjacentScreenUsesStableSpatialOrderAndCycles() {
        let top = screen(id: 30, frame: CGRect(x: 0, y: -900, width: 1_000, height: 900))
        let left = screen(id: 10, frame: CGRect(x: -1_000, y: 0, width: 1_000, height: 800))
        let main = screen(id: 20, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), isMain: true)
        let right = screen(id: 40, frame: CGRect(x: 1_000, y: 100, width: 1_200, height: 900))
        let resolver = ScreenResolver(screens: [right, main, left, top])

        // 排序为 left、top、main、right；同一 X 中按 Y 排序。
        XCTAssertEqual(resolver.adjacentScreen(from: 10, direction: .next)?.id, 30)
        XCTAssertEqual(resolver.adjacentScreen(from: 30, direction: .next)?.id, 20)
        XCTAssertEqual(resolver.adjacentScreen(from: 20, direction: .previous)?.id, 30)
        XCTAssertEqual(resolver.adjacentScreen(from: 40, direction: .next)?.id, 10)
        XCTAssertEqual(resolver.adjacentScreen(from: 10, direction: .previous)?.id, 40)
    }

    func testSingleDisplayHasNoAdjacentTarget() {
        let resolver = ScreenResolver(
            screens: [screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), isMain: true)]
        )

        XCTAssertNil(resolver.adjacentScreen(from: 1, direction: .next))
        XCTAssertNil(resolver.adjacentScreen(from: 1, direction: .previous))
    }

    func testAppKitAccessibilityConversionSupportsScreensOnEverySide() {
        let primary = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let appKitFrames = [
            CGRect(x: -1_280, y: 0, width: 1_280, height: 1_024),
            CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440),
            CGRect(x: 0, y: 1_080, width: 1_920, height: 1_080),
            CGRect(x: 0, y: -900, width: 1_600, height: 900)
        ]
        let expectedAccessibilityY: [CGFloat] = [56, -360, -1_080, 1_080]

        for (index, appKitFrame) in appKitFrames.enumerated() {
            let accessibility = ScreenResolver.accessibilityFrame(
                fromAppKit: appKitFrame,
                primaryScreenFrame: primary
            )
            let roundTrip = ScreenResolver.appKitFrame(
                fromAccessibility: accessibility,
                primaryScreenFrame: primary
            )

            XCTAssertEqual(accessibility.minY, expectedAccessibilityY[index])
            XCTAssertEqual(roundTrip, appKitFrame)
        }
    }

    private func screen(id: CGDirectDisplayID, frame: CGRect, isMain: Bool = false) -> ScreenDescriptor {
        ScreenDescriptor(id: id, frame: frame, visibleFrame: frame, isMain: isMain)
    }
}
