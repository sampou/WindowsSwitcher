import AppKit
import XCTest
@testable import WindowsSwitcher

/// 验证系统快捷键接管、权限变更及截图取消，不修改实际系统权限。
final class InteractionReliabilityTests: XCTestCase {
    func testOptionDefaultsPreserveNativeSwitching() {
        XCTAssertTrue(NativeHotKeyPolicy.suppressedKeys(
            config: HotKeyConfig(), registeredIdentifiers: ["switch", "reverseSwitch", "appSwitch"],
            accessibilityAuthorized: true
        ).isEmpty)
    }

    func testCommandTabOnlySuppressesSuccessfullyRegisteredDirections() {
        var config = HotKeyConfig()
        config.switchModifiers = 256
        XCTAssertEqual(NativeHotKeyPolicy.suppressedKeys(
            config: config, registeredIdentifiers: ["switch"], accessibilityAuthorized: true
        ), [.commandTab])
        XCTAssertEqual(NativeHotKeyPolicy.suppressedKeys(
            config: config, registeredIdentifiers: ["switch", "reverseSwitch"], accessibilityAuthorized: true
        ), [.commandTab, .commandShiftTab])
        XCTAssertTrue(NativeHotKeyPolicy.suppressedKeys(
            config: config, registeredIdentifiers: ["switch"], accessibilityAuthorized: false
        ).isEmpty)
    }

    func testDisabledSameAppShortcutPreservesNativeCommandGrave() {
        var config = HotKeyConfig()
        config.appSwitchModifiers = 256
        config.appSwitchEnabled = false
        XCTAssertTrue(NativeHotKeyPolicy.suppressedKeys(
            config: config, registeredIdentifiers: ["appSwitch"], accessibilityAuthorized: true
        ).isEmpty)
        config.appSwitchEnabled = true
        XCTAssertEqual(NativeHotKeyPolicy.suppressedKeys(
            config: config, registeredIdentifiers: ["appSwitch"], accessibilityAuthorized: true
        ), [.commandKeyAboveTab])
    }

    func testExtraModifiersDoNotSuppressNativeCommandTab() {
        var config = HotKeyConfig()
        config.switchModifiers = 256 | 2048
        XCTAssertTrue(NativeHotKeyPolicy.suppressedKeys(
            config: config, registeredIdentifiers: ["switch", "reverseSwitch"], accessibilityAuthorized: true
        ).isEmpty)
    }

    func testPermissionChecksNotifyOnceAfterBothStatusesChange() {
        let center = NotificationCenter()
        var accessibility = false
        var screenRecording = false
        let manager = PermissionManager(accessibilityCheck: { accessibility },
                                        screenRecordingCheck: { screenRecording }, notificationCenter: center)
        var notifications = 0
        let observer = center.addObserver(forName: .permissionStatusChanged, object: nil, queue: nil) { _ in
            notifications += 1
            XCTAssertTrue(manager.hasAllRequiredPermissions)
        }
        defer { center.removeObserver(observer) }
        manager.checkAllPermissions()
        XCTAssertEqual(notifications, 0)
        accessibility = true
        screenRecording = true
        manager.checkAllPermissions()
        manager.checkAllPermissions()
        XCTAssertEqual(notifications, 1)
    }

    func testPermissionRevocationIsReported() {
        let center = NotificationCenter()
        var accessibility = true
        let manager = PermissionManager(accessibilityCheck: { accessibility },
                                        screenRecordingCheck: { true }, notificationCenter: center)
        var notifications = 0
        let observer = center.addObserver(forName: .permissionStatusChanged, object: nil, queue: nil) { _ in
            notifications += 1
            XCTAssertFalse(manager.accessibilityStatus.isAuthorized)
            XCTAssertTrue(manager.screenRecordingStatus.isAuthorized)
        }
        defer { center.removeObserver(observer) }
        accessibility = false
        manager.checkAllPermissions()
        XCTAssertEqual(notifications, 1)
    }

    func testPanelCenterUsesGlobalCoordinatesForEveryDisplayPosition() {
        for frame in [CGRect(x: -1600, y: 0, width: 1600, height: 900),
                      CGRect(x: 1920, y: 100, width: 1600, height: 900),
                      CGRect(x: 0, y: -900, width: 1600, height: 900),
                      CGRect(x: 0, y: 1080, width: 1600, height: 900)] {
            let origin = SwitchPanelLayout.centeredOrigin(panelSize: CGSize(width: 800, height: 400),
                                                         screenFrame: frame)
            XCTAssertEqual(origin.x + 400, frame.midX)
            XCTAssertEqual(origin.y + 200, frame.midY)
        }
    }

    func testCancelledQueuedCaptureCompletesWithoutRunningScreenshot() async {
        let queue = OperationQueue()
        queue.isSuspended = true
        let finished = expectation(description: "取消无需等待截图队列")
        let task = Task {
            let image = await PreviewCaptureRequest.capture(on: queue) {
                XCTFail("取消的排队任务不应执行截图")
                return nil
            }
            XCTAssertNil(image)
            finished.fulfill()
        }
        for _ in 0..<100 where queue.operationCount == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(queue.operationCount, 1)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
        queue.isSuspended = false
        await task.value
        await withCheckedContinuation { continuation in
            queue.addBarrierBlock { continuation.resume() }
        }
    }

    func testBackgroundWarmingIsBoundedWithoutTruncatingThePanel() {
        let windows = (1...40).map { id in
            WindowModel(id: CGWindowID(id), appName: "App", bundleIdentifier: "com.example.app",
                        windowTitle: "Window", appIcon: NSImage(), frame: .zero,
                        isMinimized: false, isHidden: false, isOnScreen: id != 1,
                        lastActiveTime: Date(), windowLayer: 0, ownerPID: pid_t(id))
        }
        XCTAssertEqual(SwitchPanelPreviewLoadPolicy.windowsToLoad(from: windows).count, 40)
        XCTAssertEqual(BackgroundPreviewPolicy.thumbnails(from: windows).count, 12)
        XCTAssertEqual(BackgroundPreviewPolicy.thumbnails(from: windows).first?.id, 2)
        XCTAssertEqual(BackgroundPreviewPolicy.fullResolution(from: windows, enabled: true).count, 2)
        XCTAssertTrue(BackgroundPreviewPolicy.fullResolution(from: windows, enabled: false).isEmpty)
    }

    func testCaptureCompletesNormally() async {
        let image = await PreviewCaptureRequest.capture(on: OperationQueue()) {
            NSImage(size: NSSize(width: 1, height: 1))
        }
        XCTAssertNotNil(image)
    }
}
