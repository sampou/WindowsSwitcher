import CoreGraphics
import XCTest
@testable import WindowsSwitcher

final class ActionPanelViewTests: XCTestCase {
    func testActionCatalogCoversEveryLayoutCommandExactlyOnce() {
        let commands = WindowLayoutAction.all.map(\.command)

        XCTAssertEqual(commands.count, WindowLayoutCommand.allCases.count)
        for command in WindowLayoutCommand.allCases {
            XCTAssertEqual(commands.filter { $0 == command }.count, 1)
        }
    }

    func testAppliedAndConstrainedResultsUseDifferentFeedback() {
        let frame = CGRect(x: 0, y: 25, width: 960, height: 1_015)

        XCTAssertEqual(
            ActionPanelFeedback(result: .applied(frame: frame, displayID: 1)),
            .success("窗口布局已应用")
        )
        XCTAssertEqual(
            ActionPanelFeedback(result: .constrained(frame: frame, displayID: 1)),
            .constrained("应用已调整目标尺寸，请检查实际结果")
        )
    }

    func testEveryFailureHasUserFacingFeedback() {
        let failures: [WindowLayoutFailure] = [
            .accessibilityPermissionMissing,
            .windowNotFound,
            .nonStandardWindow,
            .fullScreenWindow,
            .positionNotWritable,
            .sizeNotWritable,
            .targetDisplayUnavailable,
            .writeFailed(code: 42),
            .verificationFailed
        ]

        for failure in failures {
            let feedback = ActionPanelFeedback(result: .skipped(failure))
            guard case .failure(let message) = feedback else {
                return XCTFail("失败结果应映射为用户可见反馈：\(failure)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }
}
