import XCTest
@testable import WindowsSwitcher

final class LoggerLifecycleTests: XCTestCase {
    func testCreatedLifecycleDetailContainsStableStructuredFields() {
        let detail = Logger.windowLifecycleDetail(
            event: .created,
            windowID: 42,
            appName: "Safari",
            windowTitle: "项目首页",
            bundleIdentifier: "com.apple.Safari"
        )

        XCTAssertEqual(
            detail,
            "事件=创建 | 窗口ID=42 | 应用=Safari | 标题=项目首页 | BundleID=com.apple.Safari"
        )
    }

    func testDestroyedLifecycleDetailOnlyContainsWindowID() {
        let detail = Logger.windowLifecycleDetail(event: .destroyed, windowID: 99)

        XCTAssertEqual(detail, "事件=销毁 | 窗口ID=99")
    }

    func testCreatedLifecycleDetailNormalizesDelimitersNewlinesAndEmptyValues() {
        let detail = Logger.windowLifecycleDetail(
            event: .created,
            windowID: 7,
            appName: "编辑器|预览",
            windowTitle: "第一行\n第二行",
            bundleIdentifier: "   "
        )

        XCTAssertEqual(
            detail,
            "事件=创建 | 窗口ID=7 | 应用=编辑器／预览 | 标题=第一行 第二行 | BundleID=未知"
        )
    }
}
