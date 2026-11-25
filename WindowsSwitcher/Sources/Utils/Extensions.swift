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

// MARK: - 旧版窗口活动记录迁移
/// 旧版 WindowActivityStore 以 `window_activity_<hash>` 为键逐条存储 lastActiveTime，
/// 现已并入 WindowOrderStore 快照（Entry.lastActive），统一持久化与清理路径。
///
/// 旧键是 `bundleID|title` 的 SHA256 前缀哈希，无法反查明文；
/// 迁移时对顺序快照里的每个身份键重新计算哈希去匹配，能迁移多少迁移多少。
/// 匹配不到的旧记录（如窗口已关闭）直接丢弃——lastActiveTime 只是排序的次级回退，丢失无碍。
enum LegacyWindowActivityStore {
    /// 旧存储的键前缀
    static let keyPrefix = "window_activity_"

    /// 旧存储的键生成规则：身份键字符串的 SHA256 前 16 位十六进制
    static func legacyKey(forIdentityKey identityKey: String) -> String {
        let hash = SHA256.hash(data: Data(identityKey.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return keyPrefix + String(hashString.prefix(16))
    }

    /// 将旧记录迁移进 WindowOrderStore（幂等）：迁移后删除全部旧键。
    /// - Returns: 成功合并进快照的记录数
    @discardableResult
    static func migrateIntoOrderStore() -> Int {
        let defaults = UserDefaults.standard
        let legacyKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
        guard !legacyKeys.isEmpty else { return 0 }

        let snapshot = WindowOrderStore.shared.load()
        var entries = snapshot.entries
        var migratedCount = 0
        for (identityKey, entry) in snapshot.entries where entry.lastActive == nil {
            guard let timestamp = defaults.object(forKey: legacyKey(forIdentityKey: identityKey)) as? TimeInterval else {
                continue
            }
            entries[identityKey] = WindowOrderStore.Entry(
                rank: entry.rank,
                lastSeen: entry.lastSeen,
                lastActive: Date(timeIntervalSince1970: timestamp)
            )
            migratedCount += 1
        }
        if migratedCount > 0 {
            WindowOrderStore.shared.save(WindowOrderStore.Snapshot(entries: entries, counter: snapshot.counter))
            Logger.info("迁移了 \(migratedCount) 条旧窗口活动记录到顺序快照")
        }
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
        return migratedCount
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
        /// 最后一次激活的时间（合并自旧版 WindowActivityStore，作为排序的次级回退）
        var lastActive: Date?
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

    /// 更新某个身份键的最后激活时间（只更新已存在的记录，不创建）。
    ///
    /// 激活事件即时写入，保证重启后 lastActiveTime 回退值尽量新鲜；
    /// 新窗口的名次记录由 persistWindowOrder 落盘时创建，此处不抢这个职责。
    func updateLastActiveTime(identityKey: String, time: Date) {
        let snapshot = load()
        guard var entry = snapshot.entries[identityKey] else { return }
        entry.lastActive = time
        var entries = snapshot.entries
        entries[identityKey] = entry
        save(Snapshot(entries: entries, counter: snapshot.counter))
    }

    /// 读取某个身份键的最后激活时间
    func lastActiveTime(identityKey: String) -> Date? {
        load().entries[identityKey]?.lastActive
    }

    /// 清空全部记录（测试与"重置设置"使用）
    func reset() {
        save(.empty)
    }
}
