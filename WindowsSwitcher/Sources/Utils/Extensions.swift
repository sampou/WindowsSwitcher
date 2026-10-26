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
    /// 用户在程序坞图标上悬停进入预览流程；AppDelegate 据此取消后台预取并让出截图队列。
    static let dockPreviewHoverStarted = Notification.Name("com.windowsswitcher.dockPreviewHoverStarted")
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
    private let accessibilityCheck: () -> Bool
    private let screenRecordingCheck: () -> Bool
    private let notificationCenter: NotificationCenter

    /// 注入查询函数以测试授权变更，测试不触发系统授权请求。
    init(accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         screenRecordingCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         notificationCenter: NotificationCenter = .default) {
        self.accessibilityCheck = accessibilityCheck
        self.screenRecordingCheck = screenRecordingCheck
        self.notificationCenter = notificationCenter
        checkAllPermissions()
    }

    // MARK: - 检查所有权限状态
    func checkAllPermissions() {
        // 检查辅助功能权限
        let accessibility: PermissionStatus = accessibilityCheck() ? .authorized : .denied

        // 检查屏幕录制权限
        let screenRecording: PermissionStatus = screenRecordingCheck() ? .authorized : .denied
        let changed = accessibility != accessibilityStatus || screenRecording != screenRecordingStatus
        if accessibility != accessibilityStatus { accessibilityStatus = accessibility }
        if screenRecording != screenRecordingStatus { screenRecordingStatus = screenRecording }
        // 两个状态更新后才通知；未变更的轮询不会重复重建系统监听器。
        if changed { notificationCenter.post(name: .permissionStatusChanged, object: self) }
    }

    // MARK: - 请求辅助功能权限
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkAllPermissions()
        }
    }

    // MARK: - 请求屏幕录制权限
    func requestScreenRecordingPermission(completion: ((Bool) -> Void)? = nil) {
        // 只有调用系统请求 API 才会触发 macOS 的原生屏幕录制授权提示。
        _ = CGRequestScreenCaptureAccess()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            self.checkAllPermissions()
            completion?(self.screenRecordingStatus.isAuthorized)
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
        statusCheckTimer?.tolerance = 1.0
    }

    func stopMonitoring() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
    }

    // MARK: - 获取权限说明
    func getAccessibilityPermissionDescription() -> (title: String, description: String) {
        return (
            title: L10n.text("辅助功能权限"),
            description: L10n.text("WindowsSwitcher 需要辅助功能权限来捕获窗口信息和管理窗口，实现窗口切换功能。")
        )
    }

    func getScreenRecordingPermissionDescription() -> (title: String, description: String) {
        return (
            title: L10n.text("屏幕录制权限"),
            description: L10n.text("WindowsSwitcher 需要屏幕录制权限来生成窗口预览。缩略图会保存在本地缓存中，不会通过更新请求上传；应用不录制屏幕视频。")
        )
    }

    // MARK: - 检查是否有所需权限
    var hasAllRequiredPermissions: Bool {
        return accessibilityStatus.isAuthorized && screenRecordingStatus.isAuthorized
    }

    var missingPermissions: [String] {
        var missing: [String] = []
        if !accessibilityStatus.isAuthorized {
            missing.append(L10n.text("辅助功能"))
        }
        if !screenRecordingStatus.isAuthorized {
            missing.append(L10n.text("屏幕录制"))
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

// MARK: - 窗口顺序持久化管理器
/// 保存窗口的"最近使用名次"，使应用重启后切换器的窗口顺序与上次一致。
///
/// 只保存"最后激活时间"是不够的：从未被激活过的窗口没有时间记录，
/// 重启后会被当成刚创建而排到最前，顺序整体错乱。这里保存的是名次，
/// 覆盖当前全部窗口（包括从未激活过的），因此重启后顺序可以原样恢复。
///
/// 记录以窗口身份为键（bundleID + 标题），值的名次越大表示越靠前：
/// - 窗口已关闭：记录保留在存储里，重新打开该应用时仍能恢复到原位置；
/// - 超过保留期（30 天）未出现的记录会被清理，避免无限增长；
/// - 每次保存按当前顺序重新编号，顺序变化会被如实记录下来。
///
/// 名次计数器与记录写在同一个 JSON 快照里，保证"名次 + 记录"整体原子替换：
/// 保存时新名次总是高于历史上所有名次，因此本次会话记录的活动一定排在
/// 上次会话恢复出来的窗口之前，不会出现"新窗口排到旧窗口后面"的倒序。
class WindowOrderStore {
    struct Entry: Codable, Equatable {
        /// 名次：数值越大越靠前
        var rank: UInt64
        /// 最后一次出现该窗口的时间
        var lastSeen: Date
    }

    /// 存储快照：记录 + 名次计数器
    struct Snapshot: Codable {
        var entries: [String: Entry]
        /// 历史最高名次。下次保存的新名次必须高于它。
        var counter: UInt64

        static let empty = Snapshot(entries: [:], counter: 0)
    }

    static let shared = WindowOrderStore()

    /// 记录保留期（秒）
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let userDefaults = UserDefaults.standard
    private let storageKey = "window_order_v2"
    private let lock = NSLock()
    private var cached: Snapshot?

    private init() {}

    /// 读取当前快照
    func load() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let data = userDefaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            cached = .empty
            return cached!
        }
        cached = snapshot
        return snapshot
    }

    /// 原子写入快照（单键写入，UserDefaults 保证整体替换）
    func save(_ snapshot: Snapshot) {
        lock.lock()
        cached = snapshot
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    /// 清理超过保留期的记录，返回清理数量
    @discardableResult
    func prune(olderThan cutoff: Date) -> Int {
        let snapshot = load()
        let kept = snapshot.entries.filter { $0.value.lastSeen >= cutoff }
        guard kept.count != snapshot.entries.count else { return 0 }
        save(Snapshot(entries: kept, counter: snapshot.counter))
        return snapshot.entries.count - kept.count
    }

    /// 清空全部记录（测试与"重置设置"使用）
    func reset() {
        save(.empty)
    }
}
