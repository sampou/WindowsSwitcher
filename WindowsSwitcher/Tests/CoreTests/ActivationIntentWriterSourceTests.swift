import XCTest
@testable import WindowsSwitcher

/// 激活意图写入点的结构性回归防护。
///
/// 背景：`isCurrentActivation` 用来判断"这次聚焦请求还有效吗"。它早先读的是
/// `lastActivatedWindowID`，而该字段同时被两类写入方使用：
///
/// 1. `activateWindow`——用户明确点击/选择的那个窗口（显式意图）；
/// 2. `updateActivityLocked`——0.5 秒一次的焦点轮询与激活通知（被动观测）。
///
/// 跨应用激活时，系统会先把应用"自己此前在前台的窗口"抬起来，焦点轮询随即读到它
/// 并写入同一个字段，真正的聚焦请求因此被判成"已有更新的激活请求"而取消，
/// 表现为"点的是 A，弹出来的是 B"。
///
/// 纯函数测试（`ActivationIntentTests`）只能覆盖判定逻辑本身，覆盖不了
/// "到底谁在写这个字段"。一旦将来有人在观测路径上顺手写一次，
/// 判定逻辑再正确也会被顶掉。所以这里直接清点源码里的写入点。
final class ActivationIntentWriterSourceTests: XCTestCase {

    /// 允许写入激活意图的函数名。
    ///
    /// `activateWindow` 负责发起显式意图，`clearActivationIntent` 负责在
    /// 聚焦确认成功或重试耗尽后收尾。其余任何函数（含焦点轮询、激活通知处理器）
    /// 都不允许写这三个字段。
    private static let allowedWriterFunctions: Set<String> = [
        "activateWindow",
        "clearActivationIntent"
    ]

    private static let guardedFields = [
        "pendingActivationWindowID",
        "lastActivatedWindowID",
        "lastActivatedTime"
    ]

    private func windowManagerSourceURL() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        var directory = testFile.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("Sources/Core/WindowManager/WindowManager.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        throw XCTSkip("找不到 WindowManager.swift，跳过源码写入点检查")
    }

    /// 找出每个写入点所属的函数名。
    private func writerSites(in source: String) -> [(line: Int, function: String, code: String)] {
        let lines = source.components(separatedBy: .newlines)
        var currentFunction = "<文件作用域>"
        var sites: [(line: Int, function: String, code: String)] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 记录当前所在的函数：兼容 private/public/internal 等修饰符与泛型签名。
            if trimmed.contains("func "), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") {
                let afterFunc = trimmed.components(separatedBy: "func ").last ?? ""
                let name = afterFunc
                    .components(separatedBy: "(").first?
                    .components(separatedBy: " ").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !name.isEmpty {
                    currentFunction = name
                }
            }

            for field in Self.guardedFields {
                // 只认赋值，排除 == 比较与纯读取。
                guard let range = line.range(
                    of: "\\b\(field)\\s*=[^=]",
                    options: .regularExpression
                ) else { continue }
                let code = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                sites.append((line: index + 1, function: currentFunction, code: code))
                break
            }
        }
        return sites
    }

    func testActivationIntentIsOnlyWrittenByExplicitActivationPaths() throws {
        let url = try windowManagerSourceURL()
        let source = try String(contentsOf: url, encoding: .utf8)
        let sites = writerSites(in: source)

        XCTAssertFalse(sites.isEmpty, "应当能在源码中找到激活意图字段的写入点")

        let illegal = sites.filter { !Self.allowedWriterFunctions.contains($0.function) }
        let allowed = Self.allowedWriterFunctions.sorted().joined(separator: " / ")
        let detail = illegal.map { "第 \($0.line) 行（\($0.function)）：\($0.code)" }.joined(separator: "；")
        XCTAssertTrue(
            illegal.isEmpty,
            "激活意图字段只能由 \(allowed) 写入，但以下位置也在写它们：\(detail)。"
                + "焦点轮询与激活通知属于被动观测，写入会把显式激活意图顶掉，导致\"点 A 弹出 B\"的回归。"
        )
    }

    func testObserverPathDoesNotWriteActivationIntent() throws {
        let url = try windowManagerSourceURL()
        let source = try String(contentsOf: url, encoding: .utf8)
        let sites = writerSites(in: source)

        let observerFunctions = ["updateActivityLocked", "pollFocusedWindow", "handleApplicationActivated"]
        let leaked = sites.filter { observerFunctions.contains($0.function) }
        let names = observerFunctions.joined(separator: " / ")
        let detail = leaked.map { "第 \($0.line) 行" }.joined(separator: "；")
        XCTAssertTrue(
            leaked.isEmpty,
            "被动观测路径 \(names) 不得写入激活意图字段，实际写入点：\(detail)。"
        )
    }
}
