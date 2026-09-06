import XCTest
@testable import WindowsSwitcher

/// 本地化格式化入口的回归测试。
final class LocalizationTests: XCTestCase {
    /// 验证对象参数通过正确的 CVaList 传递，避免设置页渲染时发生非法内存访问。
    func testFormatPassesObjectArgumentThroughVaList() {
        XCTAssertEqual(L10n.format("快捷键 %@", "⌘1"), "快捷键 ⌘1")
    }

    /// 验证多个字符串参数均作为 Objective-C 对象传入 `%@` 占位符。
    func testFormatPassesMultipleObjectArgumentsThroughVaList() {
        XCTAssertEqual(L10n.format("%@ %@", "窗口", "2"), "窗口 2")
    }
}
