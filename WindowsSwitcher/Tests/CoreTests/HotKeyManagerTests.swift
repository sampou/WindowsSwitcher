import XCTest
@testable import WindowsSwitcher

// MARK: - T-026 快捷键模块测试
final class HotKeyManagerTests: XCTestCase {

    // MARK: - HotKey 模型测试

    func testHotKeyCreation() {
        let hotKey = HotKey(keyCode: 48, modifiers: 256, identifier: "switch")
        XCTAssertEqual(hotKey.keyCode, 48)
        XCTAssertEqual(hotKey.modifiers, 256)
        XCTAssertEqual(hotKey.identifier, "switch")
    }

    func testHotKeyUniqueIdentifiers() {
        let hk1 = HotKey(keyCode: 48, modifiers: 256, identifier: "switch")
        let hk2 = HotKey(keyCode: 48, modifiers: 131072, identifier: "reverseSwitch")
        XCTAssertNotEqual(hk1.identifier, hk2.identifier)
    }

    // MARK: - HotKeyManager 注册/注销测试

    func testRegisterAndUnregister() {
        let manager = HotKeyManager()
        var triggered = false

        // 注册
        manager.register(
            HotKey(keyCode: 99, modifiers: 256, identifier: "test_key")
        ) { triggered = true }

        // 注销后不应再触发
        manager.unregister("test_key")

        // 再次注销不应崩溃
        manager.unregister("test_key")

        XCTAssertFalse(triggered)
    }

    func testRegisterSameIdentifierOverwrites() {
        let manager = HotKeyManager()
        var callCount = 0

        manager.register(HotKey(keyCode: 99, modifiers: 256, identifier: "dup")) { callCount += 1 }
        // 同名再注册，应覆盖旧的
        manager.register(HotKey(keyCode: 99, modifiers: 256, identifier: "dup")) { callCount += 10 }

        // 注销后不崩溃
        manager.unregister("dup")
        XCTAssertEqual(callCount, 0)
    }

    func testUnregisterNonExistentKey() {
        let manager = HotKeyManager()
        // 注销不存在的 key 不应崩溃
        XCTAssertNoThrow(manager.unregister("nonexistent"))
    }

    // MARK: - Notification.Name 测试

    func testNotificationNamesAreUnique() {
        let names: [Notification.Name] = [
            .switchHotKeyPressed,
            .reverseSwitchHotKeyPressed,
            .appSwitchHotKeyPressed,
            .windowListDidChange
        ]
        let unique = Set(names.map { $0.rawValue })
        XCTAssertEqual(unique.count, names.count, "所有通知名称应唯一")
    }

    func testNotificationPosting() {
        let expectation = expectation(description: "通知接收")
        let observer = NotificationCenter.default.addObserver(
            forName: .switchHotKeyPressed, object: nil, queue: .main
        ) { _ in expectation.fulfill() }

        NotificationCenter.default.post(name: .switchHotKeyPressed, object: nil)
        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
}
