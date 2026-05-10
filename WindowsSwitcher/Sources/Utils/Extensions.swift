import Foundation
import AppKit
import Combine
import CryptoKit

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
    // 安装相关通知
    static let showInstallProgress = Notification.Name("com.windowsswitcher.showInstallProgress")
    static let installCompleted = Notification.Name("com.windowsswitcher.installCompleted")
    static let installFailed = Notification.Name("com.windowsswitcher.installFailed")
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

// MARK: - 窗口活动记录持久化管理器
/// 用于保存窗口的最后活跃时间，实现程序重启后排序一致性
class WindowActivityStore {
    static let shared = WindowActivityStore()

    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "window_activity_"

    private init() {}

    /// 生成窗口唯一标识（使用 bundleIdentifier + windowTitle 的哈希值）
    private func windowKey(bundleIdentifier: String, windowTitle: String) -> String {
        let combined = "\(bundleIdentifier)|\(windowTitle)"
        let hash = SHA256.hash(data: Data(combined.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return keyPrefix + String(hashString.prefix(16))
    }

    /// 获取窗口的最后活跃时间
    func getLastActiveTime(bundleIdentifier: String, windowTitle: String) -> Date? {
        let key = windowKey(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle)
        guard let timestamp = userDefaults.object(forKey: key) as? TimeInterval else {
            Logger.debug("WindowActivityStore: No stored time for \(bundleIdentifier) - \(windowTitle)")
            return nil
        }
        let date = Date(timeIntervalSince1970: timestamp)
        Logger.debug("WindowActivityStore: Retrieved time \(date) for \(bundleIdentifier) - \(windowTitle)")
        return date
    }

    /// 保存窗口的最后活跃时间
    func saveLastActiveTime(bundleIdentifier: String, windowTitle: String, time: Date) {
        guard !bundleIdentifier.isEmpty else { return }
        let key = windowKey(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle)
        userDefaults.set(time.timeIntervalSince1970, forKey: key)
        Logger.debug("WindowActivityStore: Saved time \(time) for \(bundleIdentifier) - \(windowTitle)")
    }

    /// 清理过期记录（超过30天未活跃的窗口）
    func cleanupOldRecords() {
        let cutoffDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let allKeys = userDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(keyPrefix) }

        var cleanedCount = 0
        for key in allKeys {
            guard let timestamp = userDefaults.object(forKey: key) as? TimeInterval else { continue }
            let date = Date(timeIntervalSince1970: timestamp)
            if date < cutoffDate {
                userDefaults.removeObject(forKey: key)
                cleanedCount += 1
            }
        }

        if cleanedCount > 0 {
            Logger.info("Cleaned \(cleanedCount) old window activity records")
        }
    }

    /// 获取所有存储的窗口数量（用于调试）
    func getStoredWindowCount() -> Int {
        return userDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(keyPrefix) }
            .count
    }
}
