import Foundation
import AppKit
import Combine

// MARK: - NSImage helpers
extension NSImage {
    func resized(to size: CGSize) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: size),
             from: NSRect(origin: .zero, size: self.size),
             operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}

// MARK: - String fuzzy match
extension String {
    /// BUG-012: 原实现只做 contains，与 FilterEngine 的字符序列匹配不一致
    /// 改为与 FilterEngine.fuzzyMatch 相同的逻辑：子串优先，降级字符序列
    func fuzzyMatch(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        let t = self.lowercased()
        if t.contains(q) { return true }
        var qi = q.startIndex
        for ch in t {
            guard qi < q.endIndex else { return true }
            if ch == q[qi] { qi = q.index(after: qi) }
        }
        return qi == q.endIndex
    }
}

// MARK: - Notification names
extension Notification.Name {
    static let switchHotKeyPressed = Notification.Name("com.windowsswitcher.switchHotKey")
    static let reverseSwitchHotKeyPressed = Notification.Name("com.windowsswitcher.reverseSwitchHotKey")
    static let appSwitchHotKeyPressed = Notification.Name("com.windowsswitcher.appSwitchHotKey")
    static let appSwitchReverseHotKeyPressed = Notification.Name("com.windowsswitcher.appSwitchReverseHotKey")
    static let windowListDidChange = Notification.Name("com.windowsswitcher.windowListDidChange")
    static let dockPreviewWindowSelected = Notification.Name("com.windowsswitcher.dockPreviewWindowSelected")
    static let permissionStatusChanged = Notification.Name("com.windowsswitcher.permissionStatusChanged")
}

// MARK: - 权限状态枚举
enum PermissionStatus: String, Codable {
    case notDetermined = "未确定"
    case denied = "被拒绝"
    case authorized = "已授权"

    var isAuthorized: Bool {
        return self == .authorized
    }
}

// MARK: - 权限管理器
class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    // 权限状态
    @Published var accessibilityStatus: PermissionStatus = .notDetermined
    @Published var screenRecordingStatus: PermissionStatus = .notDetermined

    private var cancellables = Set<AnyCancellable>()
    private var statusCheckTimer: Timer?

    private init() {
        checkAllPermissions()
    }

    // MARK: - 检查所有权限状态
    func checkAllPermissions() {
        // 检查辅助功能权限
        let hasAccessibility = AXIsProcessTrusted()
        accessibilityStatus = hasAccessibility ? .authorized : .denied

        // 检查屏幕录制权限
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
        screenRecordingStatus = hasScreenRecording ? .authorized : .denied
    }

    // MARK: - 请求辅助功能权限
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkAllPermissions()
            NotificationCenter.default.post(name: .permissionStatusChanged, object: nil)
        }
    }

    // MARK: - 请求屏幕录制权限
    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkAllPermissions()
            NotificationCenter.default.post(name: .permissionStatusChanged, object: nil)
        }
    }

    // MARK: - 打开系统设置
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 启动/停止权限监测
    func startMonitoring() {
        stopMonitoring()
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkAllPermissions()
        }
    }

    func stopMonitoring() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
    }

    // MARK: - 获取权限说明
    func getAccessibilityPermissionDescription() -> (title: String, description: String) {
        return (
            title: "辅助功能权限",
            description: "WindowsSwitcher 需要辅助功能权限来捕获窗口信息和管理窗口，实现窗口切换功能。"
        )
    }

    func getScreenRecordingPermissionDescription() -> (title: String, description: String) {
        return (
            title: "屏幕录制权限",
            description: "WindowsSwitcher 需要屏幕录制权限来生成窗口预览缩略图，显示实时窗口内容。此权限不会录制或保存任何内容。"
        )
    }

    // MARK: - 检查是否有所需权限
    var hasAllRequiredPermissions: Bool {
        return accessibilityStatus.isAuthorized && screenRecordingStatus.isAuthorized
    }

    var missingPermissions: [String] {
        var missing: [String] = []
        if !accessibilityStatus.isAuthorized {
            missing.append("辅助功能")
        }
        if !screenRecordingStatus.isAuthorized {
            missing.append("屏幕录制")
        }
        return missing
    }
}
