import XCTest
import CoreGraphics
@testable import WindowsSwitcher

/// 事件 tap 被系统禁用时的恢复策略。
///
/// 该策略同时被切换面板的 ESC tap 与智能目录粘贴的常驻 tap 使用，
/// 因此单独固化测试，避免两处实现出现分歧。
final class EventTapRecoveryTests: XCTestCase {

    func testTimeoutDisabledTriggersReenable() {
        XCTAssertEqual(EventTapRecovery.action(for: .tapDisabledByTimeout), .reenable)
    }

    func testUserInputDisabledTriggersReenable() {
        XCTAssertEqual(EventTapRecovery.action(for: .tapDisabledByUserInput), .reenable)
    }

    func testNormalEventsNeedNoRecovery() {
        XCTAssertEqual(EventTapRecovery.action(for: .keyDown), .none)
        XCTAssertEqual(EventTapRecovery.action(for: .keyUp), .none)
        XCTAssertEqual(EventTapRecovery.action(for: .flagsChanged), .none)
    }

    func testReenableWithoutTapReportsFailure() {
        XCTAssertFalse(EventTapRecovery.reenable(nil))
    }
}
