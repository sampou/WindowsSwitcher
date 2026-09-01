import AppKit
import XCTest
@testable import WindowsSwitcher

@MainActor
final class WindowItemAccessibilityTests: XCTestCase {
    func testPrimaryActionSelectsBeforeActivating() {
        var events: [String] = []
        let view = makeView(
            onSelect: { events.append("select") },
            onActivate: { events.append("activate") }
        )

        view.performPrimaryAction()

        XCTAssertEqual(events, ["select", "activate"])
    }

    func testAccessibilityCopyMatchesSingleActionBehavior() {
        XCTAssertEqual(WindowItemView.activationAccessibilityHint, "按下 Return 键切换到该窗口")
        XCTAssertEqual(WindowItemView.minimizeAccessibilityAction, "最小化窗口")
        XCTAssertEqual(WindowItemView.closeAccessibilityAction, "关闭窗口")
    }

    private func makeView(
        onSelect: @escaping () -> Void = {},
        onActivate: @escaping () -> Void = {}
    ) -> WindowItemView {
        WindowItemView(
            window: WindowModel(
                id: 1,
                appName: "测试应用",
                bundleIdentifier: "com.example.test",
                windowTitle: "测试窗口",
                appIcon: NSImage(),
                frame: .zero,
                isMinimized: false,
                isHidden: false,
                isOnScreen: true,
                lastActiveTime: .distantPast,
                windowLayer: 0,
                ownerPID: 1
            ),
            isSelected: true,
            previewImage: nil,
            onSelect: onSelect,
            onActivate: onActivate,
            onClose: {},
            onMinimize: {}
        )
    }
}
