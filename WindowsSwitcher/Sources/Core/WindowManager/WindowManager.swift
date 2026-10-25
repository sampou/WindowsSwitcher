import AppKit
import CoreGraphics

// 私有 API：通过 AXUIElement 获取对应的 CGWindowID
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WindowEvent {
    case windowCreated(WindowModel)
    case windowDestroyed(CGWindowID)
    case windowStateChanged(WindowModel)
}

/// 窗口聚焦操作的执行线程策略。
///
/// 对本进程窗口执行 AX Raise 时，辅助功能调用会回到 AppKit 的 `NSWindow`，必须在主线程执行；
/// 外部进程窗口仍放在后台队列，避免辅助功能 API 阻塞切换器界面。
struct WindowFocusExecutionPolicy {
    static func requiresMainThread(targetPID: pid_t, currentPID: pid_t) -> Bool {
        targetPID == currentPID
    }
}

/// 精确窗口聚焦后的确认与退避重试策略。
///
/// `NSRunningApplication.activate` 和目标应用自身的窗口恢复可能异步改写焦点，因此不能把
/// `kAXRaiseAction` 返回成功等同于最终焦点正确。短暂确认后按退避间隔重试，可覆盖该竞争窗口。
struct WindowFocusRetryPolicy {
    static let verificationDelay: TimeInterval = 0.04
    private static let retryDelays: [TimeInterval] = [0.04, 0.08, 0.16]

    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval? {
        guard retryDelays.indices.contains(attempt) else { return nil }
        return retryDelays[attempt]
    }
}

/// AX 跨进程采集的时间预算与候选窗口收敛规则。
struct AXWindowFilteringPolicy {
    static let perElementTimeout: TimeInterval = 0.15
    static let totalBudget: TimeInterval = 0.20
    static let circuitBreakerThreshold = 3
    static let circuitBreakerCooldown: TimeInterval = 5

    static func candidateOwnerPIDs(in windowInfoList: [[String: Any]]) -> Set<pid_t> {
        Set(windowInfoList.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowOwnerPID as String] as? pid_t
        })
    }

    static func timeout(remainingBudget: TimeInterval) -> TimeInterval? {
        guard remainingBudget > 0 else { return nil }
        return min(perElementTimeout, remainingBudget)
    }
}

/// 最小化窗口提供器：在后台维护"已最小化"的窗口列表。
///
/// CG 层无法区分"已最小化"与"在其它 Space"（两者的 kCGWindowIsOnscreen 都是 false），
/// 只能通过 AX 的 kAXMinimized 判定。而逐进程查询 AX 是跨进程调用（本机实测 40+ 进程
/// 需要秒级），因此放在后台分批推进，主线程只读取已经完成的缓存。
///
/// 另有两个必要细节：
/// - 无 AX 响应的进程（辅助进程、注入式程序）会被记入负缓存，避免每次扫描都白等超时；
/// - 最小化窗口的标题与几何取自 CG 枚举（AX 在最小化时位置不可靠）。
final class MinimizedWindowProvider: @unchecked Sendable {
    /// 单个进程的判定结果
    private struct Entry {
        var models: [WindowModel]
        var checkedAt: Date
    }

    private var cache: [pid_t: Entry] = [:]
    /// 无 AX 响应的进程：短时间内不再查询
    private var unresponsive: [pid_t: Date] = [:]
    private let lock = NSLock()
    /// 扫描游标：让候选进程轮流被刷新
    private var scanCursor = 0
    private var lastScanStartedAt: Date?
    /// 上一次已知的最小化窗口数量（用于变化时打日志）
    private var lastKnownMinimizedCount = 0
    /// 已执行的扫描轮数
    private var scanRounds = 0

    /// 缓存有效期（秒）
    private static let entryTTL: TimeInterval = 5.0
    /// 无响应进程的跳过时长（秒）
    private static let unresponsiveTTL: TimeInterval = 60.0
    /// 两次后台扫描的最小间隔（秒）
    private static let scanInterval: TimeInterval = 2.0
    /// 单个 AX 元素的超时（秒）
    private static let perElementTimeout: TimeInterval = 0.05
    /// 批量扫描时查询进程 AX 窗口列表的超时（秒）
    private static let perApplicationTimeout: TimeInterval = 0.25
    /// 按需即时查询的超时（秒）：面向用户正在悬停的应用，宁可慢也要准
    private static let immediateQueryTimeout: TimeInterval = 0.6
    /// 单轮扫描处理的进程数上限
    private static let maxPIDsPerScan = 16

    /// 查询单个进程的最小化窗口（可注入，便于单元测试）
    ///
    /// - Parameters:
    ///   - pid: 目标进程
    ///   - timeout: 查询该进程 AX 窗口列表的超时（秒）
    ///   - windowInfo: CG 窗口信息快照（窗口 ID -> 原始字典）
    typealias Query = @Sendable (pid_t, TimeInterval, [CGWindowID: [String: Any]]) -> [WindowModel]?

    private let query: Query

    init(query: @escaping Query = { pid, timeout, info in
        MinimizedWindowProvider.queryMinimizedWindows(pid: pid, timeout: timeout, windowInfo: info)
    }) {
        self.query = query
    }

    /// 读取缓存中的最小化窗口（主线程安全）。
    func cachedWindows(excluding knownIDs: Set<CGWindowID>) -> [WindowModel] {
        lock.lock()
        defer { lock.unlock() }
        var result: [WindowModel] = []
        for entry in cache.values {
            for model in entry.models where !knownIDs.contains(model.id) {
                result.append(model)
            }
        }
        return result
    }

    /// 指定进程的最小化窗口。
    ///
    /// 缓存有效时直接返回；允许即时查询时（程序坞预览针对悬停应用）会同步做一次单进程查询。
    func windows(for pid: pid_t, allowImmediateQuery: Bool = true) -> [WindowModel] {
        let now = Date()
        lock.lock()
        let entry = cache[pid]
        let unresponsiveAt = unresponsive[pid]
        lock.unlock()

        if let entry, now.timeIntervalSince(entry.checkedAt) < Self.entryTTL {
            return entry.models
        }
        guard allowImmediateQuery else { return [] }
        if let unresponsiveAt, now.timeIntervalSince(unresponsiveAt) < Self.unresponsiveTTL {
            return []
        }

        // 即时查询面向用户正在看的应用，给更长的 AX 超时以保证准确
        guard let models = query(pid, Self.immediateQueryTimeout, [:]) else {
            lock.lock()
            unresponsive[pid] = now
            lock.unlock()
            return []
        }

        store(pid: pid, models: models)
        return models.map { $0.isMinimized ? $0 : $0.withMinimizedState(true) }
    }

    /// 后台刷新一批进程的最小化窗口（每轮只处理有限个进程，轮流推进）。
    ///
    /// - Parameters:
    ///   - pids: 候选进程
    ///   - windowInfo: CG 窗口信息快照；最小化窗口不在 .optionOnScreenOnly 结果里，
    ///                 必须用 .optionAll 的快照才能取到标题与几何
    func refresh(pids: [pid_t], windowInfo: [CGWindowID: [String: Any]] = [:]) {
        let now = Date()
        lock.lock()
        if let last = lastScanStartedAt, now.timeIntervalSince(last) < Self.scanInterval {
            lock.unlock()
            return
        }
        lastScanStartedAt = now
        let unresponsiveSnapshot = unresponsive
        let start = scanCursor
        lock.unlock()

        guard !pids.isEmpty else { return }
        let batchSize = min(Self.maxPIDsPerScan, pids.count)
        for offset in 0..<batchSize {
            let pid = pids[(start + offset) % pids.count]
            if let at = unresponsiveSnapshot[pid], now.timeIntervalSince(at) < Self.unresponsiveTTL { continue }
            guard let models = query(pid, Self.perApplicationTimeout, windowInfo) else {
                lock.lock()
                unresponsive[pid] = now
                lock.unlock()
                continue
            }
            store(pid: pid, models: models)
        }

        lock.lock()
        scanCursor = (start + batchSize) % max(pids.count, 1)
        let round = scanRounds
        scanRounds += 1
        let total = cache.values.reduce(0) { $0 + $1.models.count }
        lock.unlock()

        if round < 3 {
            Logger.operation(
                "最小化扫描",
                detail: "第 \(round + 1) 轮，处理 \(batchSize)/\(pids.count) 个进程",
                result: "累计识别 \(total) 个"
            )
        }
    }

    private func store(pid: pid_t, models: [WindowModel]) {
        let models = models.map { model in
            model.isMinimized ? model : model.withMinimizedState(true)
        }
        lock.lock()
        cache[pid] = Entry(models: models, checkedAt: Date())
        unresponsive.removeValue(forKey: pid)
        let total = cache.values.reduce(0) { $0 + $1.models.count }
        let changed = total != lastKnownMinimizedCount
        if changed { lastKnownMinimizedCount = total }
        lock.unlock()

        if changed, total > 0 {
            Logger.operation("最小化窗口", detail: "已识别 \(total) 个（进程 \(pid)）", result: "已并入窗口列表")
        }
    }

    /// 查询指定进程的最小化窗口。
    ///
    /// AX 判定最小化状态并给出窗口 ID，标题与几何取自 CG 枚举。
    /// AX 完全不可用时返回 nil（调用方据此记入负缓存）。
    private static func queryMinimizedWindows(
        pid: pid_t,
        timeout: TimeInterval,
        windowInfo: [CGWindowID: [String: Any]]
    ) -> [WindowModel]? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Float(timeout))

        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let axWindows = windowList as? [AXUIElement] else {
            return nil
        }

        var minimizedIDs: Set<CGWindowID> = []
        var standardFlags: [CGWindowID: Bool] = [:]

        for axWindow in axWindows {
            AXUIElementSetMessagingTimeout(axWindow, Float(perElementTimeout))

            var cgWindowID: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &cgWindowID) == .success, cgWindowID != 0 else { continue }

            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let flag = minimizedRef as? Bool, flag, flag else { continue }

            minimizedIDs.insert(cgWindowID)
            standardFlags[cgWindowID] = NonStandardWindowRules.isStandardAccessibilityWindow(
                role: stringAttribute(kAXRoleAttribute as CFString, of: axWindow),
                subrole: stringAttribute(kAXSubroleAttribute as CFString, of: axWindow)
            )
        }

        guard !minimizedIDs.isEmpty else { return [] }

        guard let app = NSRunningApplication(processIdentifier: pid) else { return [] }
        let bundleID = app.bundleIdentifier ?? ""
        let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        let appName = app.localizedName ?? "Unknown"

        var models: [WindowModel] = []
        for windowID in minimizedIDs {
            guard let info = cgWindowInfo(for: windowID, in: windowInfo) else { continue }
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let frame = CGRect(
                x: (bounds["X"] as? CGFloat) ?? 0,
                y: (bounds["Y"] as? CGFloat) ?? 0,
                width: (bounds["Width"] as? CGFloat) ?? 0,
                height: (bounds["Height"] as? CGFloat) ?? 0
            )
            guard frame.width > 0, frame.height > 0 else { continue }

            // 与主枚举保持同一套规则：非标准窗口不应出现在窗口列表里。
            // 否则最小化时能看见、还原后却消失，两条路径的判定不一致。
            guard !NonStandardWindowRules.isNonStandardWindow(
                bundleIdentifier: bundleID,
                appName: appName,
                windowTitle: title,
                frame: frame,
                windowLayer: 0
            ) else { continue }

            models.append(WindowModel(
                id: windowID,
                appName: appName,
                bundleIdentifier: bundleID,
                windowTitle: title,
                appIcon: icon,
                frame: frame,
                isMinimized: true,
                isHidden: false,
                isOnScreen: false,
                lastActiveTime: Date(),
                windowLayer: 0,
                ownerPID: pid,
                isStandardWindow: standardFlags[windowID] ?? true
            ))
        }

        return models
    }

    /// 读取单个窗口的 CG 信息（包含离屏窗口）。
    ///
    /// 注意：`.optionIncludingWindow` 对离屏窗口返回空结果，
    /// 最小化窗口必须从 `.optionAll` 快照里取。
    private static func cgWindowInfo(
        for windowID: CGWindowID,
        in windowInfo: [CGWindowID: [String: Any]]
    ) -> [String: Any]? {
        if let info = windowInfo[windowID] { return info }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return list.first { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}

/// 连续耗尽预算时临时关闭 AX 过滤，确保切换器优先保持可用。
struct AXWindowFilteringCircuitBreaker {
    private var consecutiveBudgetExhaustions = 0
    private var disabledUntil: Date?

    mutating func isEnabled(now: Date) -> Bool {
        guard let disabledUntil else { return true }
        guard now < disabledUntil else {
            self.disabledUntil = nil
            consecutiveBudgetExhaustions = 0
            return true
        }
        return false
    }

    /// 返回是否在本次记录后进入临时降级状态。
    mutating func record(budgetExhausted: Bool, now: Date) -> Bool {
        guard budgetExhausted else {
            consecutiveBudgetExhaustions = 0
            return false
        }

        consecutiveBudgetExhaustions += 1
        guard consecutiveBudgetExhaustions >= AXWindowFilteringPolicy.circuitBreakerThreshold else {
            return false
        }

        disabledUntil = now.addingTimeInterval(AXWindowFilteringPolicy.circuitBreakerCooldown)
        return true
    }
}

private struct AXWindowCollectionResult {
    let nonStandardWindowIDs: Set<CGWindowID>
    let candidateProcessCount: Int
    let successfulProcessCount: Int
    let failedProcessCount: Int
    let budgetExhausted: Bool
    let elapsedMilliseconds: Int
    let attempted: Bool

    static let skipped = AXWindowCollectionResult(
        nonStandardWindowIDs: [],
        candidateProcessCount: 0,
        successfulProcessCount: 0,
        failedProcessCount: 0,
        budgetExhausted: false,
        elapsedMilliseconds: 0,
        attempted: false
    )
}

/// CGWindowID 是系统截图和窗口激活的唯一标识；重复条目只保留最前面的一个。
struct WindowIDDeduplicator {
    static func unique(_ windows: [WindowModel]) -> [WindowModel] {
        var seen = Set<CGWindowID>()
        return windows.filter { seen.insert($0.id).inserted }
    }
}

/// 系统窗口快照的创建/销毁差分。
///
/// 创建事件保持当前快照顺序，销毁事件按窗口 ID 排序，确保生产行为与测试结果稳定。
struct WindowSnapshotReconciler {
    static func events(
        previous: [CGWindowID: WindowModel],
        current: [WindowModel],
        hasBaseline: Bool
    ) -> [WindowEvent] {
        // 首次成功枚举只建立基线，不能把应用启动前已存在的窗口误报为新建。
        guard hasBaseline else { return [] }

        let previousIDs = Set(previous.keys)
        let currentIDs = Set(current.map(\.id))

        let createdEvents = current
            .filter { !previousIDs.contains($0.id) }
            .map(WindowEvent.windowCreated)
        let destroyedEvents = previousIDs
            .subtracting(currentIDs)
            .sorted()
            .map(WindowEvent.windowDestroyed)

        return createdEvents + destroyedEvents
    }
}

/// 可取消的窗口生命周期轮询任务。
protocol WindowLifecyclePollingToken: AnyObject {
    func invalidate()
}

extension Timer: WindowLifecyclePollingToken {}

/// 线程安全的进程内窗口活动序号存储。
///
/// `WindowManager` 仍使用自己的状态锁保证窗口缓存与活动序号的组合更新原子性；本类型
/// 额外封装序号自身的并发读写，使记录、首次观察、清理和快照语义可以被确定性测试。
final class WindowActivitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var globalSequence: UInt64 = 0
    private var sequenceByWindowID: [CGWindowID: UInt64] = [:]
    private var revisionValue: UInt64 = 0

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revisionValue
    }

    @discardableResult
    func record(windowID: CGWindowID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        globalSequence &+= 1
        sequenceByWindowID[windowID] = globalSequence
        revisionValue &+= 1
        return globalSequence
    }

    @discardableResult
    func recordFirstObservation(windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sequenceByWindowID[windowID] == nil else { return false }
        globalSequence &+= 1
        sequenceByWindowID[windowID] = globalSequence
        revisionValue &+= 1
        return true
    }

    @discardableResult
    func remove(windowIDs: Set<CGWindowID>) -> Bool {
        guard !windowIDs.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let previousCount = sequenceByWindowID.count
        windowIDs.forEach { sequenceByWindowID.removeValue(forKey: $0) }
        guard sequenceByWindowID.count != previousCount else { return false }
        revisionValue &+= 1
        return true
    }

    func bumpRevision() {
        lock.lock()
        revisionValue &+= 1
        lock.unlock()
    }

    func snapshot() -> [CGWindowID: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return sequenceByWindowID
    }
}

/// 低频触发系统窗口枚举，并统一管理启动、暂停与停止语义。
///
/// 该类型不理解窗口排序或事件差分；生产环境只注入一次强制枚举，创建/销毁事件仍由
/// `WindowSnapshotReconciler` 产生。测试可注入调度器和枚举闭包，无需依赖真实 RunLoop。
final class WindowLifecyclePoller: @unchecked Sendable {
    typealias Tick = @Sendable () -> Void
    typealias Scheduler = @Sendable (TimeInterval, @escaping Tick) -> WindowLifecyclePollingToken

    static let defaultInterval: TimeInterval = 2.0

    private let condition = NSCondition()
    private let interval: TimeInterval
    private let enumerateWindows: () -> Void
    private let scheduler: Scheduler

    private var token: WindowLifecyclePollingToken?
    private var generation: UInt64 = 0
    private var isRunning = false
    private var isPaused = false
    private var isEnumerating = false

    init(
        interval: TimeInterval = WindowLifecyclePoller.defaultInterval,
        enumerateWindows: @escaping () -> Void,
        scheduler: @escaping Scheduler = { interval, tick in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
        }
    ) {
        self.interval = interval
        self.enumerateWindows = enumerateWindows
        self.scheduler = scheduler
    }

    /// 启动轮询；重复调用会替换旧任务，不会叠加定时器。
    func start() {
        condition.lock()
        generation &+= 1
        let currentGeneration = generation
        isRunning = true
        let previousToken = token
        token = nil
        condition.unlock()

        previousToken?.invalidate()
        let newToken = scheduler(interval) { [weak self] in
            self?.tick(generation: currentGeneration)
        }

        condition.lock()
        if isRunning, generation == currentGeneration {
            token = newToken
            condition.unlock()
        } else {
            condition.unlock()
            newToken.invalidate()
        }
    }

    /// 暂停或恢复枚举。暂停返回时，已经开始的枚举也已结束。
    func setPaused(_ paused: Bool) {
        condition.lock()
        isPaused = paused
        while paused, isEnumerating {
            condition.wait()
        }
        condition.unlock()
    }

    /// 停止轮询。返回后不会再启动新的枚举，且在途枚举已经收口。
    func stop() {
        condition.lock()
        generation &+= 1
        isRunning = false
        let currentToken = token
        token = nil
        condition.unlock()

        currentToken?.invalidate()

        condition.lock()
        while isEnumerating {
            condition.wait()
        }
        condition.unlock()
    }

    private func tick(generation expectedGeneration: UInt64) {
        condition.lock()
        guard isRunning,
              !isPaused,
              generation == expectedGeneration,
              !isEnumerating else {
            condition.unlock()
            return
        }
        isEnumerating = true
        condition.unlock()

        enumerateWindows()

        condition.lock()
        isEnumerating = false
        condition.broadcast()
        condition.unlock()
    }
}

protocol WindowManagerProtocol {
    func getAllWindows(forceRefresh: Bool) -> [WindowModel]
    func activitySequenceSnapshot() -> [CGWindowID: UInt64]
    func activateWindow(_ window: WindowModel)
    func closeWindow(_ window: WindowModel)
    func minimizeWindow(_ window: WindowModel)
    func hideWindow(_ window: WindowModel)
    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void)
    func refreshCache()
}

extension WindowManagerProtocol {
    /// 兼容不关心 MRU 精度的测试替身；生产 WindowManager 必须覆盖真实快照。
    func activitySequenceSnapshot() -> [CGWindowID: UInt64] { [:] }
}

class WindowManager: WindowManagerProtocol {
    // 单例实例
    static let shared = WindowManager()

    private var eventHandler: ((WindowEvent) -> Void)?
    private var windowCache: [CGWindowID: WindowModel] = [:]
    /// 是否至少完成过一次成功的系统窗口枚举；与“已有空快照”是不同状态。
    private var hasWindowSnapshotBaseline = false
    private var observers: [NSObjectProtocol] = []

    // 窗口列表缓存（避免频繁调用 CGWindowListCopyWindowInfo）
    private var cachedWindows: [WindowModel] = []
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 0.1 // 100ms 缓存，支持快速切换

    // 应用信息缓存（PID -> bundleID / 图标 / 隐藏状态）
    private var appInfoCache: [pid_t: AppInfo] = [:]

    /// 最小化窗口提供器：后台用 AX 判定哪些窗口处于最小化状态
    private let minimizedWindowProvider = MinimizedWindowProvider()

    /// 最小化窗口扫描队列（后台执行，主线程不等待）
    private let minimizedScanQueue = DispatchQueue(
        label: "com.windowsswitcher.minimized-scan",
        qos: .utility
    )

    /// 应用信息缓存有效期（秒）。
    ///
    /// 超过该时间重新读取 bundleID，避免 PID 被系统复用后仍沿用旧应用的归属。
    private static let appInfoCacheTTL: TimeInterval = 2.0

    /// 单个应用的信息快照。
    private struct AppInfo {
        let bundleIdentifier: String
        let icon: NSImage
        let isHidden: Bool
        let refreshedAt: Date
    }

    // 线程安全锁：保护窗口缓存、活动序号、焦点窗口与缓存版本
    // 后台预取线程和主线程并发读写这些 Dictionary 会触发 EXC_BAD_ACCESS
    private let stateLock = NSLock()

    // 进程内窗口活动序号（不跨启动持久化）
    private let activitySequence = WindowActivitySequence()

    // 串行化 CGWindow/AX 快照，避免远程桌面或虚拟显示变化时旧快照覆盖新快照。
    private let enumerationLock = NSLock()

    // 焦点窗口轮询定时器（用于监听同一应用内的窗口切换，如 Command+`）
    private var focusPollingTimer: Timer?
    // 低频主动枚举，用于发现未伴随应用激活通知的外部窗口创建/销毁。
    private var windowLifecyclePoller: WindowLifecyclePoller?
    private var lastFocusedWindowID: CGWindowID?
    private var pendingFocusedWindowID: CGWindowID?
    private var pendingFocusedPID: pid_t?
    private var pendingFocusTime: Date?

    // 记录刚激活的窗口（防止 didActivateApplicationNotification 错误更新其他窗口）
    private var lastActivatedWindowID: CGWindowID?
    private var lastActivatedTime: Date?
    private var axFilterCircuitBreaker = AXWindowFilteringCircuitBreaker()

    private init() {}

    // 缓存的窗口列表
    var windows: [WindowModel] {
        getAllWindows()
    }

    deinit {
        stopFocusPolling()
        stopWindowLifecyclePolling()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// 调用方必须已持有 stateLock。
    private func recordActivityLocked(windowID: CGWindowID) {
        activitySequence.record(windowID: windowID)
        cacheTimestamp = nil
    }

    /// 调用方必须已持有 stateLock。
    private func recordFirstObservationLocked(windowID: CGWindowID) {
        guard activitySequence.recordFirstObservation(windowID: windowID) else { return }
        cacheTimestamp = nil
    }

    /// 调用方必须已持有 stateLock。
    private func removeActivityLocked(windowIDs: Set<CGWindowID>) {
        guard !windowIDs.isEmpty else { return }
        let activityDidChange = activitySequence.remove(windowIDs: windowIDs)
        var focusDidChange = false
        if let lastFocusedWindowID, windowIDs.contains(lastFocusedWindowID) {
            self.lastFocusedWindowID = nil
            focusDidChange = true
        }
        if focusDidChange, !activityDidChange {
            // 活动序号清理会自行递增 revision；只有纯焦点变化时才单独补版本。
            activitySequence.bumpRevision()
        }
        if activityDidChange || focusDidChange {
            cacheTimestamp = nil
        }
    }

    func getAllWindows(forceRefresh: Bool = false) -> [WindowModel] {
        enumerationLock.lock()

        stateLock.lock()

        // 强制刷新时清除缓存时间戳
        if forceRefresh {
            cacheTimestamp = nil
        }

        // 使用缓存，避免频繁调用
        let now = Date()
        if !forceRefresh,
           let timestamp = cacheTimestamp,
           now.timeIntervalSince(timestamp) < cacheTTL,
           !cachedWindows.isEmpty {
            let result = cachedWindows
            stateLock.unlock()
            enumerationLock.unlock()
            return result
        }

        let axFilteringEnabled = axFilterCircuitBreaker.isEnabled(now: now)
        // AX 是同步跨进程调用。采集必须在 stateLock 外完成，避免目标应用无响应时
        // 阻塞缓存读写和快捷键触发的同步刷新。
        stateLock.unlock()

        // 基础枚举只取当前屏幕上的窗口：CG 层的 .optionAll 会带来大量其它 Space、
        // 辅助进程与光标覆盖层等噪声窗口。
        // 已最小化的窗口由 MinimizedWindowProvider 在后台用 AX 判定后并入。
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            stateLock.lock()
            let stableWindows = cachedWindows
            stateLock.unlock()
            enumerationLock.unlock()
            Logger.warning("CGWindowListCopyWindowInfo failed; retaining previous window snapshot")
            return stableWindows
        }

        // 远程桌面/虚拟显示重配置时可能短暂得到空集合；保留稳定快照，避免全量销毁。
        if list.isEmpty {
            stateLock.lock()
            let stableWindows = cachedWindows
            stateLock.unlock()
            enumerationLock.unlock()
            Logger.warning("CGWindowListCopyWindowInfo returned empty snapshot; retaining previous window snapshot")
            return stableWindows
        }

        let axCollection = axFilteringEnabled
            ? collectNonStandardAccessibilityWindows(for: AXWindowFilteringPolicy.candidateOwnerPIDs(in: list))
            : .skipped

        // 后台推进最小化窗口的 AX 判定（主线程不等待）
        scheduleMinimizedWindowScan(for: list)

        stateLock.lock()
        if axCollection.attempted {
            let circuitOpened = axFilterCircuitBreaker.record(
                budgetExhausted: axCollection.budgetExhausted,
                now: Date()
            )
            logAXCollection(axCollection, circuitOpened: circuitOpened)
        } else if !axFilteringEnabled {
            Logger.warning("AX窗口过滤临时降级：连续预算耗尽后仅使用基础窗口规则")
        }

        // CGWindow 的 layer 不足以区分应用搜索浮层等 layer 0 面板。
        // 仅在 AX API 能按 CGWindowID 精确识别为非标准窗口时排除；不可访问的应用保持原有行为。
        let onScreenWindows = WindowIDDeduplicator.unique(list.compactMap {
            buildWindowModel(from: $0, nonStandardAccessibilityWindowIDs: axCollection.nonStandardWindowIDs)
        })

        // 并入后台判定出的最小化窗口：它们不在当前屏幕上，但可以还原并切过去。
        // 保留此前记录的最近使用时间，避免并入时打乱 MRU 顺序。
        let onScreenIDs = Set(onScreenWindows.map(\.id))
        let minimizedWindows = minimizedWindowProvider.cachedWindows(excluding: onScreenIDs).map { model in
            let cachedTime = windowCache[model.id]?.lastActiveTime
            let time = cachedTime ?? WindowActivityStore.shared.getLastActiveTime(
                bundleIdentifier: model.bundleIdentifier,
                windowTitle: model.windowTitle
            ) ?? model.lastActiveTime
            return model.withLastActiveTime(time)
        }
        let windows = onScreenWindows + minimizedWindows
        let windowEvents = WindowSnapshotReconciler.events(
            previous: windowCache,
            current: windows,
            hasBaseline: hasWindowSnapshotBaseline
        )
        let currentWindowIDs = Set(windows.map(\.id))
        let staleWindowIDs = Set(windowCache.keys).subtracting(currentWindowIDs)

        for window in windows {
            windowCache[window.id] = window
            if window.id == pendingFocusedWindowID,
               pendingFocusedPID == window.ownerPID,
               pendingFocusTime.map({ Date().timeIntervalSince($0) < 2.0 }) == true {
                updateActivityLocked(for: window, at: Date())
                clearPendingFocusLocked()
            }
            // 不把 CGWindow 枚举顺序当作 MRU；其他新窗口等待真实焦点/激活事件记录活动。
        }
        staleWindowIDs.forEach { windowCache.removeValue(forKey: $0) }
        // 远程桌面/虚拟显示短暂丢失窗口时，不删除活动序号；窗口重新出现仍沿用原有 MRU 元数据。
        hasWindowSnapshotBaseline = true

        let revision = activitySequence.revision
        let activitySequenceSnapshot = activitySequence.snapshot()
        stateLock.unlock()

        // 排序闭包不得持有 WindowManager.stateLock。
        let sortedWindows = WindowOrdering().sort(
            windows,
            by: .recent,
            activitySequence: activitySequenceSnapshot
        )

        stateLock.lock()
        // 活动状态变化时不把基于旧快照的结果写回缓存，避免覆盖失效信号。
        if activitySequence.revision == revision {
            cachedWindows = sortedWindows
            cacheTimestamp = now
        }
        stateLock.unlock()
        enumerationLock.unlock()

        // 事件回调可能触发面板刷新；必须在 WindowManager 锁外执行，避免重入死锁。
        emitWindowEvents(windowEvents)
        return sortedWindows
    }

    /// 强制刷新窗口缓存
    func refreshCache() {
        stateLock.lock()
        cacheTimestamp = nil
        stateLock.unlock()
    }

    func activitySequenceSnapshot() -> [CGWindowID: UInt64] {
        stateLock.lock()
        let snapshot = activitySequence.snapshot()
        stateLock.unlock()
        return snapshot
    }

    @discardableResult
    func recordFocusedWindowActivity(pid: pid_t) -> CGWindowID? {
        guard let windowID = getFocusedWindowID(pid: pid) else {
            stateLock.lock()
            markPendingFocusLocked(pid: pid)
            stateLock.unlock()
            return nil
        }

        stateLock.lock()
        // 焦点可能早于 CGWindow 枚举进入；此时仅记录 pending，下一次快照会消费。
        guard let model = windowCache[windowID], model.ownerPID == pid else {
            markPendingFocusLocked(pid: pid, windowID: windowID)
            stateLock.unlock()
            return windowID
        }

        updateActivityLocked(for: model, at: Date())
        clearPendingFocusLocked()
        stateLock.unlock()
        return windowID
    }

    /// 在窗口快照建立后重新协调前台窗口。
    /// AX 在新应用启动瞬间可能暂时无法返回焦点窗口；若该应用当前只有一个可见窗口，
    /// 该唯一候选是无歧义的安全兜底，否则保留 pending 状态，绝不猜测多个窗口中的某一个。
    @discardableResult
    func reconcileFocusedWindow(pid: pid_t) -> CGWindowID? {
        var updatedModel: WindowModel?

        if let windowID = getFocusedWindowID(pid: pid) {
            stateLock.lock()
            if let model = windowCache[windowID], model.ownerPID == pid {
                // 如果本次焦点已经记录且没有待处理意图，不重复推进活动序号。
                let shouldRecord = lastFocusedWindowID != windowID || pendingFocusedPID == pid
                if shouldRecord {
                    updateActivityLocked(for: model, at: Date())
                    updatedModel = windowCache[windowID]
                }
                clearPendingFocusLocked()
                stateLock.unlock()
                if let updatedModel {
                    emitWindowEvents([.windowStateChanged(updatedModel)])
                }
                return windowID
            }
            markPendingFocusLocked(pid: pid, windowID: windowID)
            stateLock.unlock()
            return nil
        }

        stateLock.lock()
        let candidates = windowCache.values.filter {
            $0.ownerPID == pid && $0.isOnScreen && !$0.isMinimized && !$0.isHidden
        }
        let pendingIsRecent = pendingFocusedPID == pid
            && pendingFocusTime.map { Date().timeIntervalSince($0) < 1.0 } == true
        guard pendingIsRecent, candidates.count == 1, let candidate = candidates.first else {
            stateLock.unlock()
            return nil
        }

        updateActivityLocked(for: candidate, at: Date())
        updatedModel = windowCache[candidate.id]
        clearPendingFocusLocked()
        stateLock.unlock()
        Logger.debug("==> Focus AX unavailable; promoted unique visible window for PID \(pid)")
        if let updatedModel {
            emitWindowEvents([.windowStateChanged(updatedModel)])
        }
        return candidate.id
    }

    /// 在新应用启动或窗口刚创建的短暂 AX 延迟期间，重试解析其精确焦点窗口。
    /// 只在 AX 返回具体窗口 ID，或同 PID 只有一个无歧义可见窗口时记录活动；绝不猜测多窗口应用。
    func scheduleFocusedWindowReconciliation(pid: pid_t) {
        let retryDelays: [TimeInterval] = [0.05, 0.15, 0.30]
        for delay in retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // 每次重试都先刷新快照，覆盖“激活通知/AX 焦点早于 CGWindow 枚举”的顺序。
                _ = self.reconcileFocusedWindow(pid: pid)
                _ = self.getAllWindows(forceRefresh: true)
            }
        }
    }

    /// 调用方必须已持有 stateLock。
    private func markPendingFocusLocked(pid: pid_t, windowID: CGWindowID? = nil) {
        pendingFocusedWindowID = windowID
        pendingFocusedPID = pid
        pendingFocusTime = Date()
    }

    /// 调用方必须已持有 stateLock。
    private func clearPendingFocusLocked() {
        pendingFocusedWindowID = nil
        pendingFocusedPID = nil
        pendingFocusTime = nil
    }

    /// 调用方必须已持有 stateLock。
    private func updateActivityLocked(for model: WindowModel, at time: Date) {
        windowCache[model.id] = WindowModel(
            id: model.id,
            appName: model.appName,
            bundleIdentifier: model.bundleIdentifier,
            windowTitle: model.windowTitle,
            appIcon: model.appIcon,
            frame: model.frame,
            isMinimized: model.isMinimized,
            isHidden: model.isHidden,
            isOnScreen: model.isOnScreen,
            lastActiveTime: time,
            windowLayer: model.windowLayer,
            ownerPID: model.ownerPID,
            isStandardWindow: model.isStandardWindow
        )
        recordActivityLocked(windowID: model.id)
        lastFocusedWindowID = model.id
        lastActivatedWindowID = model.id
        lastActivatedTime = time
    }

    /// 后台推进最小化窗口判定。
    ///
    /// AX 查询是跨进程调用（本机实测数十个进程需要秒级），必须放到后台，
    /// 主线程只读取 MinimizedWindowProvider 已完成的缓存。
    private func scheduleMinimizedWindowScan(for windowInfoList: [[String: Any]]) {
        minimizedScanQueue.async { [weak self] in
            guard let self else { return }
            // 只有"拥有离屏窗口"的进程才可能拥有最小化窗口：
            // 最小化窗口在 CG 列表里就是离屏的。
            let snapshot = Self.offScreenWindowSnapshot()
            guard !snapshot.pids.isEmpty else { return }
            self.minimizedWindowProvider.refresh(pids: snapshot.pids, windowInfo: snapshot.info)
        }
    }

    /// 离屏窗口快照：进程列表 + 窗口原始信息。
    ///
    /// 必须用 .optionAll：最小化窗口不在 .optionOnScreenOnly 的结果里，
    /// 且 .optionIncludingWindow 对离屏窗口返回空结果。
    /// 该枚举在后台线程执行，不占用主线程。
    private static func offScreenWindowSnapshot() -> (pids: [pid_t], info: [CGWindowID: [String: Any]]) {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return ([], [:])
        }

        var pids: [pid_t] = []
        var seen = Set<pid_t>()
        var info: [CGWindowID: [String: Any]] = [:]

        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            guard !onScreen else { continue }
            if !seen.contains(pid) {
                seen.insert(pid)
                pids.append(pid)
            }
            info[windowID] = entry
        }

        return (pids, info)
    }

    /// 指定应用的最小化窗口（程序坞预览用：按需单进程查询，代价可接受）。
    func minimizedWindows(forBundleID bundleID: String) -> [WindowModel] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        var models: [WindowModel] = []
        for app in apps {
            models.append(contentsOf: minimizedWindowProvider.windows(for: app.processIdentifier))
        }
        return models.map { model in
            model.withLastActiveTime(resolvedLastActive(for: model))
        }
    }

    /// 程序坞预览用：某个应用的窗口列表（含刚查询到的最小化窗口）。
    ///
    /// 排序按创建时间（CGWindowID 升序），与切换面板的"最近使用优先"是两套独立规则：
    /// 程序坞预览需要稳定的位置对应关系，点击过某个窗口不应让它下次就跳到最前。
    /// 列表本身不排序，由调用方按需要排列。
    func dockPreviewWindows(forBundleID bundleID: String) -> [WindowModel] {
        var windows = getAllWindows()
        let existingIDs = Set(windows.map(\.id))
        let minimized = minimizedWindows(forBundleID: bundleID).filter { !existingIDs.contains($0.id) }
        guard !minimized.isEmpty else { return windows }

        windows.append(contentsOf: minimized)
        return windows
    }

    /// 解析窗口的最近使用时间：优先内存缓存，其次持久化记录。
    private func resolvedLastActive(for model: WindowModel) -> Date {
        stateLock.lock()
        let cached = windowCache[model.id]?.lastActiveTime
        stateLock.unlock()
        if let cached { return cached }
        return WindowActivityStore.shared.getLastActiveTime(
            bundleIdentifier: model.bundleIdentifier,
            windowTitle: model.windowTitle
        ) ?? model.lastActiveTime
    }

    /// 激活前按窗口 ID 重新解析实时窗口。
    ///
    /// 预览面板持有的是悬停时的快照：点击时窗口可能已经关闭，或 CGWindowID 已被系统
    /// 回收给另一个窗口。直接激活旧快照会命中另一个窗口，因此这里重新枚举并校验归属；
    /// 目标确实消失时返回 nil，宁可不激活，也不激活到别的窗口。
    func resolveWindowForActivation(_ snapshot: WindowModel) -> WindowModel? {
        let current = getAllWindows(forceRefresh: true)

        // 首选：ID、归属进程与 bundle 均未变化，且标题或几何仍与快照一致。
        // 只比 ID/进程不够：CGWindowID 会被窗口服务器回收给同应用的新建窗口，
        // 那样会激活到另一个窗口（标题与几何都不一致即可判定为 ID 复用）。
        if let live = current.first(where: {
            $0.id == snapshot.id
                && $0.ownerPID == snapshot.ownerPID
                && $0.bundleIdentifier == snapshot.bundleIdentifier
                && Self.isSameWindow($0, snapshot)
        }) {
            return live
        }

        // 兜底：应用重建窗口导致 ID 变化时，用“同进程 + 标题 + 几何”做一次受限匹配；
        // 命中多个候选时放弃激活，避免猜错窗口。
        let candidates = current.filter { candidate in
            candidate.ownerPID == snapshot.ownerPID
                && !candidate.windowTitle.isEmpty
                && candidate.windowTitle == snapshot.windowTitle
                && abs(candidate.frame.origin.x - snapshot.frame.origin.x) < 24
                && abs(candidate.frame.origin.y - snapshot.frame.origin.y) < 24
                && abs(candidate.frame.width - snapshot.frame.width) < 24
                && abs(candidate.frame.height - snapshot.frame.height) < 24
        }

        if candidates.count == 1 {
            Logger.operation(
                "窗口重新解析",
                detail: "\(snapshot.appName) - \(snapshot.windowTitle)",
                result: "按标题与几何匹配"
            )
            return candidates[0]
        }

        return nil
    }

    /// 判断实时窗口与快照是否仍是同一个窗口：标题一致，或位置/尺寸仍然接近。
    ///
    /// 标题变化但窗口没换（文档改名、网页标题更新）时由几何兜底；
    /// 标题与几何都变了则判定为 CGWindowID 被复用。
    static func isSameWindow(_ live: WindowModel, _ snapshot: WindowModel) -> Bool {
        if !snapshot.windowTitle.isEmpty, live.windowTitle == snapshot.windowTitle {
            return true
        }
        return abs(live.frame.origin.x - snapshot.frame.origin.x) < 40
            && abs(live.frame.origin.y - snapshot.frame.origin.y) < 40
            && abs(live.frame.width - snapshot.frame.width) < 40
            && abs(live.frame.height - snapshot.frame.height) < 40
    }

    func activateWindow(_ window: WindowModel) {
        // 操作日志：开始激活窗口
        Logger.operation("窗口激活开始", detail: "\(window.appName) - \(window.windowTitle) (ID: \(window.id), PID: \(window.ownerPID))")

        // 获取应用实例
        let app: NSRunningApplication
        if let runningApp = NSRunningApplication(processIdentifier: window.ownerPID) {
            app = runningApp
        } else {
            Logger.warning("Failed to get NSRunningApplication for PID: \(window.ownerPID), trying bundleID")

            // 降级：尝试通过 bundleIdentifier 查找应用
            let bundleID = window.bundleIdentifier
            guard let appByBundle = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                Logger.warning("Failed to find NSRunningApplication for bundleID: \(bundleID)")
                return
            }
            let result = appByBundle.activate(options: [.activateIgnoringOtherApps])
            Logger.operation("窗口激活", detail: "通过 bundleID 激活", result: result ? "成功" : "失败")
            app = appByBundle
        }

        // 立即更新目标窗口的 lastActiveTime（避免 didActivateApplicationNotification 更新错误的窗口）
        let now = Date()
        stateLock.lock()
        windowCache[window.id] = WindowModel(
            id: window.id,
            appName: window.appName,
            bundleIdentifier: window.bundleIdentifier,
            windowTitle: window.windowTitle,
            appIcon: window.appIcon,
            frame: window.frame,
            isMinimized: window.isMinimized,
            isHidden: window.isHidden,
            isOnScreen: window.isOnScreen,
            lastActiveTime: now,
            windowLayer: window.windowLayer,
            ownerPID: window.ownerPID,
            isStandardWindow: window.isStandardWindow
        )
        recordActivityLocked(windowID: window.id)
        lastFocusedWindowID = window.id
        lastActivatedWindowID = window.id
        lastActivatedTime = now
        stateLock.unlock()

        // 持久化保存窗口活动时间（异步执行，不阻塞激活）
        DispatchQueue.global(qos: .utility).async {
            WindowActivityStore.shared.saveLastActiveTime(
                bundleIdentifier: window.bundleIdentifier,
                windowTitle: window.windowTitle,
                time: now
            )
        }

        // 检查目标应用是否已经是前台应用
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier

        if isFrontmost {
            // 同一应用内切换窗口：按目标进程选择安全的聚焦线程
            Logger.operation("应用内切换", detail: "\(window.appName) - \(window.windowTitle)", result: "调度聚焦")
            scheduleQuickFocus(window, delay: 0)
        } else {
            // 不同应用间切换：先激活应用，再聚焦目标窗口
            Logger.operation("跨应用切换", detail: "激活 \(window.appName) - \(window.windowTitle)", result: "激活应用")
            let _ = app.activate(options: [.activateIgnoringOtherApps])
            scheduleQuickFocus(window, delay: 0.05)
        }

        Logger.operation("窗口激活完成", detail: "\(window.appName) - \(window.windowTitle)")
    }

    /// 根据目标窗口所属进程调度 AX 聚焦操作。
    private func scheduleQuickFocus(_ window: WindowModel, delay: TimeInterval, attempt: Int = 0) {
        let work: @Sendable () -> Void = { [weak self] in
            self?.focusWindowAndConfirm(window, attempt: attempt)
        }
        let deadline = DispatchTime.now() + delay
        let requiresMainThread = WindowFocusExecutionPolicy.requiresMainThread(
            targetPID: window.ownerPID,
            currentPID: ProcessInfo.processInfo.processIdentifier
        )

        if requiresMainThread {
            Logger.operation("窗口聚焦调度", detail: "\(window.appName) - \(window.windowTitle)", result: "主线程")
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
        } else {
            Logger.operation("窗口聚焦调度", detail: "\(window.appName) - \(window.windowTitle)", result: "后台线程")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline, execute: work)
        }
    }

    /// 聚焦目标窗口，并读取应用当前焦点窗口 ID 做结果确认。
    ///
    /// 设置应用的 focusedWindow 与窗口的 main/focused 属性后再执行 Raise，兼容 Chrome 等
    /// 多窗口应用。确认失败只会重试当前最新的激活请求，避免旧任务覆盖用户后续选择。
    private func focusWindowAndConfirm(_ window: WindowModel, attempt: Int) {
        guard isCurrentActivation(window.id) else {
            Logger.operation("窗口聚焦取消", detail: "\(window.appName) - \(window.windowTitle)", result: "已有更新的激活请求")
            return
        }
        guard let win = axWindow(for: window) else {
            retryWindowFocusIfNeeded(window, attempt: attempt, actualWindowID: nil)
            return
        }

        let axApp = AXUIElementCreateApplication(window.ownerPID)
        _ = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let appFocusResult = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, win)
        let mainResult = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focusResult = AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raiseResult = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        Logger.operation(
            "AX 精确聚焦",
            detail: "\(window.appName) - \(window.windowTitle), attempt=\(attempt + 1), appFocus=\(appFocusResult.rawValue), main=\(mainResult.rawValue), focus=\(focusResult.rawValue), raise=\(raiseResult.rawValue)",
            result: raiseResult == .success ? "已提交" : "部分失败"
        )

        let verify: @Sendable () -> Void = { [weak self] in
            guard let self, self.isCurrentActivation(window.id) else { return }
            let actualWindowID = self.getFocusedWindowID(pid: window.ownerPID)
            if actualWindowID == window.id {
                Logger.operation("窗口聚焦确认", detail: "\(window.appName) - \(window.windowTitle) (ID: \(window.id))", result: "成功")
            } else {
                self.retryWindowFocusIfNeeded(window, attempt: attempt, actualWindowID: actualWindowID)
            }
        }
        dispatchFocusWork(
            for: window,
            delay: WindowFocusRetryPolicy.verificationDelay,
            work: verify
        )
    }

    /// 当前请求仍是最新激活目标时，按退避策略重新聚焦。
    private func retryWindowFocusIfNeeded(
        _ window: WindowModel,
        attempt: Int,
        actualWindowID: CGWindowID?
    ) {
        guard isCurrentActivation(window.id) else { return }
        guard let delay = WindowFocusRetryPolicy.retryDelay(afterAttempt: attempt) else {
            Logger.operation(
                "窗口聚焦确认",
                detail: "目标 ID: \(window.id), 实际 ID: \(actualWindowID.map(String.init) ?? "未知")",
                result: "失败 - 已耗尽重试"
            )
            return
        }
        Logger.operation(
            "窗口聚焦重试",
            detail: "目标 ID: \(window.id), 实际 ID: \(actualWindowID.map(String.init) ?? "未知"), nextAttempt=\(attempt + 2)",
            result: "等待 \(Int(delay * 1000))ms"
        )
        scheduleQuickFocus(window, delay: delay, attempt: attempt + 1)
    }

    /// 根据目标进程选择正确线程执行 AX 操作。
    private func dispatchFocusWork(
        for window: WindowModel,
        delay: TimeInterval,
        work: @escaping @Sendable () -> Void
    ) {
        let deadline = DispatchTime.now() + delay
        if WindowFocusExecutionPolicy.requiresMainThread(
            targetPID: window.ownerPID,
            currentPID: ProcessInfo.processInfo.processIdentifier
        ) {
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline, execute: work)
        }
    }

    /// 判断异步聚焦任务是否仍对应最新一次窗口激活请求。
    private func isCurrentActivation(_ windowID: CGWindowID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastActivatedWindowID == windowID
    }

    /// 聚焦指定窗口
    private func focusWindow(_ window: WindowModel, retryCount: Int) {
        guard let win = axWindow(for: window) else {
            Logger.warning("Cannot find AXUIElement for window: \(window.windowTitle)")

            // 重试（减少延迟）
            if retryCount < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.focusWindow(window, retryCount: retryCount + 1)
                }
            }
            return
        }

        // 先 raise 窗口，再设置焦点
        let raiseResult = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        let focusResult = AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        Logger.operation("AX 操作", detail: "raise=\(raiseResult.rawValue), focus=\(focusResult.rawValue)",
                         result: raiseResult == .success && focusResult == .success ? "成功" : "部分失败")

        if focusResult != .success || raiseResult != .success {
            // 再尝试一次（减少延迟）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self = self, let win = self.axWindow(for: window) else { return }
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    func closeWindow(_ window: WindowModel) {
        guard let win = axWindow(for: window) else { return }
        var closeButton: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &closeButton)
        if let btn = closeButton, CFGetTypeID(btn) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }

    func minimizeWindow(_ window: WindowModel) {
        guard let win = axWindow(for: window) else { return }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    func hideWindow(_ window: WindowModel) {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else { return }
        app.hide()
    }

    func observeWindowChanges(_ handler: @escaping (WindowEvent) -> Void) {
        stateLock.lock()
        eventHandler = handler
        stateLock.unlock()
        // BUG-003: 先移除旧 observer，防止重复注册
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()

        // 停止之前的轮询
        stopFocusPolling()
        stopWindowLifecyclePolling()

        // 监听应用激活事件，追踪外部窗口切换（窗口级别）
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }

            // 如果焦点轮询被暂停，跳过处理
            if self.isWindowPollingPaused() { return }

            // 获取激活的应用
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            let pid = app.processIdentifier
            Logger.debug("==> External app activated: \(app.localizedName ?? "unknown"), PID: \(pid)")

            // 检查是否是刚激活的窗口所在的应用（500ms 内）
            // 如果是，且检测到的焦点窗口不同于刚激活的窗口，跳过更新，避免错误更新同应用的其他窗口
            self.stateLock.lock()
            if let activatedID = self.lastActivatedWindowID,
               let activatedTime = self.lastActivatedTime,
               Date().timeIntervalSince(activatedTime) < 0.5 {
                // 获取刚激活窗口所属的应用PID
                if let activatedWindow = self.windowCache[activatedID],
                   activatedWindow.ownerPID == pid {
                    self.stateLock.unlock()
                    // 同一应用的激活事件，检查焦点窗口是否匹配
                    let focusedWindowID = self.getFocusedWindowID(pid: pid)
                    if focusedWindowID != activatedID {
                        // AX API 返回了同应用的其他窗口，跳过更新
                        Logger.debug("==> Skipping wrong window update: activated=\(activatedID), detected=\(focusedWindowID ?? 0)")
                        return
                    }
                } else {
                    self.stateLock.unlock()
                }
            } else {
                self.stateLock.unlock()
            }

            // 使用 AX API 获取当前焦点窗口（窗口级别追踪）
            let focusedWindowID = self.getFocusedWindowID(pid: pid)
            let now = Date()

            self.stateLock.lock()
            if let windowID = focusedWindowID, var model = self.windowCache[windowID] {
                // 只更新焦点窗口的 lastActiveTime
                model = WindowModel(
                    id: model.id,
                    appName: model.appName,
                    bundleIdentifier: model.bundleIdentifier,
                    windowTitle: model.windowTitle,
                    appIcon: model.appIcon,
                    frame: model.frame,
                    isMinimized: model.isMinimized,
                    isHidden: model.isHidden,
                    isOnScreen: model.isOnScreen,
                    lastActiveTime: now,
                    windowLayer: model.windowLayer,
                    ownerPID: model.ownerPID,
                    isStandardWindow: model.isStandardWindow
                )
                self.windowCache[windowID] = model
                self.recordActivityLocked(windowID: windowID)
                self.lastFocusedWindowID = windowID
                self.stateLock.unlock()
                Logger.debug("==> Updated lastActiveTime for focused window: \(model.windowTitle)")
            } else {
                // AX 无法确认焦点时，不把同一应用的任意窗口伪造为最近使用。
                // 远程桌面/虚拟显示可能不暴露本地焦点，保留既有活动元数据。
                self.stateLock.unlock()
                Logger.debug("==> Focus window unavailable for PID \(pid); preserving activity metadata")
            }
        }
        observers.append(token)

        // 启动焦点窗口轮询，监听同一应用内的窗口切换（如 Command+`）
        startFocusPolling()
        // 系统没有覆盖所有窗口创建/销毁的可靠通知，低频枚举用于补齐生命周期事件。
        startWindowLifecyclePolling()
    }

    // MARK: - 焦点轮询暂停（切换面板打开时暂停，避免窗口列表变化）

    /// 由 `stateLock` 保护，应用激活回调、焦点轮询和面板控制可能来自不同线程。
    private var focusPollingPaused = false

    /// 暂停焦点轮询（切换面板打开时调用）
    func pauseFocusPolling() {
        stateLock.lock()
        focusPollingPaused = true
        let lifecyclePoller = windowLifecyclePoller
        stateLock.unlock()
        lifecyclePoller?.setPaused(true)
    }

    /// 恢复焦点轮询（切换面板关闭时调用）
    func resumeFocusPolling() {
        stateLock.lock()
        focusPollingPaused = false
        let lifecyclePoller = windowLifecyclePoller
        stateLock.unlock()
        lifecyclePoller?.setPaused(false)
    }

    /// 查询统一轮询暂停状态，避免通知回调与面板线程无锁竞争。
    private func isWindowPollingPaused() -> Bool {
        stateLock.lock()
        let paused = focusPollingPaused
        stateLock.unlock()
        return paused
    }

    /// 启动窗口生命周期主动枚举。枚举间隔独立于 500ms 的焦点轮询。
    private func startWindowLifecyclePolling() {
        stateLock.lock()
        let poller: WindowLifecyclePoller
        if let existing = windowLifecyclePoller {
            poller = existing
        } else {
            let created = WindowLifecyclePoller { [weak self] in
                _ = self?.getAllWindows(forceRefresh: true)
            }
            windowLifecyclePoller = created
            poller = created
        }
        let paused = focusPollingPaused
        stateLock.unlock()

        poller.setPaused(paused)
        poller.start()
    }

    /// 停止窗口生命周期主动枚举，并等待在途枚举完成。
    private func stopWindowLifecyclePolling() {
        stateLock.lock()
        let poller = windowLifecyclePoller
        stateLock.unlock()
        poller?.stop()
    }

    // MARK: - 焦点窗口轮询

    /// 启动焦点窗口轮询定时器
    private func startFocusPolling() {
        focusPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollFocusedWindow()
        }
    }

    /// 停止焦点窗口轮询
    private func stopFocusPolling() {
        focusPollingTimer?.invalidate()
        focusPollingTimer = nil
    }

    /// 轮询检查焦点窗口变化
    private func pollFocusedWindow() {
        // 如果焦点轮询被暂停，跳过处理
        guard !isWindowPollingPaused() else { return }

        // 获取当前前台应用的焦点窗口
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontmostApp.processIdentifier

        guard let focusedWindowID = getFocusedWindowID(pid: pid) else {
            stateLock.lock()
            markPendingFocusLocked(pid: pid)
            stateLock.unlock()
            return
        }

        let now = Date()
        stateLock.lock()
        guard let model = windowCache[focusedWindowID], model.ownerPID == pid else {
            markPendingFocusLocked(pid: pid, windowID: focusedWindowID)
            stateLock.unlock()
            return
        }
        guard focusedWindowID != lastFocusedWindowID else {
            stateLock.unlock()
            return
        }

        updateActivityLocked(for: model, at: now)
        clearPendingFocusLocked()
        stateLock.unlock()

        Logger.debug("==> Focus window changed (same app): \(model.windowTitle)")
        emitWindowEvents([.windowStateChanged(model)])
    }

    /// 复制回调后在锁外逐个派发，避免回调重入 WindowManager 时发生死锁。
    private func emitWindowEvents(_ events: [WindowEvent]) {
        guard !events.isEmpty else { return }
        stateLock.lock()
        let handler = eventHandler
        stateLock.unlock()
        guard let handler else { return }
        events.forEach(handler)
    }

    /// 获取指定应用的焦点窗口 ID
    private func getFocusedWindowID(pid: pid_t) -> CGWindowID? {
        let axApp = AXUIElementCreateApplication(pid)

        // 获取焦点窗口
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let window = focusedWindow else {
            Logger.debug("==> Failed to get focused window for PID \(pid): \(result.rawValue)")
            return nil
        }

        // 通过私有 API 获取 CGWindowID
        var windowID: CGWindowID = 0
        let windowResult = _AXUIElementGetWindow(window as! AXUIElement, &windowID)

        guard windowResult == .success else {
            Logger.debug("==> Failed to get CGWindowID: \(windowResult.rawValue)")
            return nil
        }

        return windowID
    }

    /// 在总预算内收集可精确识别的非标准 AX 窗口。失败或预算耗尽的进程按保守策略放行。
    private func collectNonStandardAccessibilityWindows(for ownerPIDs: Set<pid_t>) -> AXWindowCollectionResult {
        let start = ProcessInfo.processInfo.systemUptime
        var result = Set<CGWindowID>()
        var successfulProcessCount = 0
        var failedProcessCount = 0
        var budgetExhausted = false

        for ownerPID in ownerPIDs.sorted() {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            guard let applicationTimeout = AXWindowFilteringPolicy.timeout(
                remainingBudget: AXWindowFilteringPolicy.totalBudget - elapsed
            ) else {
                budgetExhausted = true
                break
            }

            let application = AXUIElementCreateApplication(ownerPID)
            AXUIElementSetMessagingTimeout(application, Float(applicationTimeout))
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else {
                failedProcessCount += 1
                continue
            }
            successfulProcessCount += 1

            for window in windows {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                guard let windowTimeout = AXWindowFilteringPolicy.timeout(
                    remainingBudget: AXWindowFilteringPolicy.totalBudget - elapsed
                ) else {
                    budgetExhausted = true
                    break
                }

                AXUIElementSetMessagingTimeout(window, Float(windowTimeout))
                var windowID: CGWindowID = 0
                guard _AXUIElementGetWindow(window, &windowID) == .success else { continue }

                var roleValue: CFTypeRef?
                let role = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue) == .success
                    ? roleValue as? String
                    : nil
                let elapsedAfterRole = ProcessInfo.processInfo.systemUptime - start
                guard let subroleTimeout = AXWindowFilteringPolicy.timeout(
                    remainingBudget: AXWindowFilteringPolicy.totalBudget - elapsedAfterRole
                ) else {
                    budgetExhausted = true
                    break
                }
                AXUIElementSetMessagingTimeout(window, Float(subroleTimeout))
                var subroleValue: CFTypeRef?
                let subrole = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue) == .success
                    ? subroleValue as? String
                    : nil

                if !NonStandardWindowRules.isStandardAccessibilityWindow(role: role, subrole: subrole) {
                    result.insert(windowID)
                }
            }

            if budgetExhausted { break }
        }

        let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        return AXWindowCollectionResult(
            nonStandardWindowIDs: result,
            candidateProcessCount: ownerPIDs.count,
            successfulProcessCount: successfulProcessCount,
            failedProcessCount: failedProcessCount,
            budgetExhausted: budgetExhausted,
            elapsedMilliseconds: elapsedMilliseconds,
            attempted: true
        )
    }

    /// 仅记录计数与耗时，不写入窗口标题、搜索文本或应用页面内容。
    private func logAXCollection(_ result: AXWindowCollectionResult, circuitOpened: Bool) {
        let detail = "候选进程=\(result.candidateProcessCount) 成功=\(result.successfulProcessCount) 失败=\(result.failedProcessCount) 预算耗尽=\(result.budgetExhausted) 排除窗口=\(result.nonStandardWindowIDs.count) 耗时毫秒=\(result.elapsedMilliseconds)"
        if circuitOpened {
            Logger.warning("AX窗口过滤触发临时降级：\(detail)")
        } else if result.budgetExhausted || result.failedProcessCount > 0 {
            Logger.info("AX窗口过滤降级采集：\(detail)")
        } else {
            Logger.debug("AX窗口过滤采集：\(detail)")
        }
    }

    private func buildWindowModel(
        from info: [String: Any],
        nonStandardAccessibilityWindowIDs: Set<CGWindowID>
    ) -> WindowModel? {
        guard
            let windowID = info[kCGWindowNumber as String] as? CGWindowID,
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0
        else { return nil }

        guard !nonStandardAccessibilityWindowIDs.contains(windowID) else {
            Logger.debug("Skipping AX non-standard window: ID \(windowID)")
            return nil
        }

        let appName = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
        let windowTitle = info[kCGWindowName as String] as? String ?? ""
        let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false

        let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let frame = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        // 使用应用信息缓存，避免重复加载图标
        // 线程安全：由 getAllWindows 的 stateLock 保护
        //
        // 缓存必须有有效期：进程退出后 PID 会被系统复用给另一个应用，
        // 无限期缓存会把新应用的窗口挂到旧应用的 bundleID 下，
        // 程序坞预览会因此显示并激活成另一个应用。
        let now = Date()
        let cached = appInfoCache[ownerPID]
        let appInfo: AppInfo
        if let cached, now.timeIntervalSince(cached.refreshedAt) < Self.appInfoCacheTTL {
            appInfo = cached
        } else {
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let bundleID = app?.bundleIdentifier ?? ""
            // bundleID 变化说明 PID 已被复用，图标必须一并刷新
            let icon: NSImage
            if let cached, cached.bundleIdentifier == bundleID {
                icon = cached.icon
            } else {
                icon = app?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            }
            appInfo = AppInfo(
                bundleIdentifier: bundleID,
                icon: icon,
                isHidden: app?.isHidden ?? false,
                refreshedAt: now
            )
            appInfoCache[ownerPID] = appInfo
        }

        // 基础枚举只包含屏幕上的窗口，最小化窗口由 MinimizedWindowProvider 并入，
        // 因此这里的最小化标记恒为 false。
        let isMinimized = false

        // BUG-011: lastActiveTime 始终为 Date()，无法反映真实 LRU 顺序
        // 优先级：内存缓存 > 持久化存储 > 当前时间
        // 新窗口（不在缓存中）且在屏幕上：直接用 Date()，避免 WindowActivityStore
        // 返回旧时间戳导致新窗口排序靠后（如同名浏览器标签）
        let lastActive: Date
        if let cached = windowCache[windowID]?.lastActiveTime {
            lastActive = cached
        } else if isOnScreen {
            lastActive = Date()
        } else {
            lastActive = WindowActivityStore.shared.getLastActiveTime(
                bundleIdentifier: appInfo.bundleIdentifier,
                windowTitle: windowTitle
            ) ?? Date()
        }

        Logger.debug("Window \(appName) - \(windowTitle): lastActiveTime = \(lastActive)")

        // 判断是否为标准窗口
        let isStandardWindow = !NonStandardWindowRules.isNonStandardWindow(
            bundleIdentifier: appInfo.bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            frame: frame,
            windowLayer: layer
        )

        // 如果不是标准窗口，直接返回 nil（不包含在窗口列表中）
        guard isStandardWindow else {
            Logger.debug("Skipping non-standard window: \(appName) - \(windowTitle) [\(frame.width)x\(frame.height)]")
            return nil
        }

        return WindowModel(
            id: windowID,
            appName: appName,
            bundleIdentifier: appInfo.bundleIdentifier,
            windowTitle: windowTitle,
            appIcon: appInfo.icon,
            frame: frame,
            isMinimized: isMinimized,
            isHidden: appInfo.isHidden,
            isOnScreen: isOnScreen,
            lastActiveTime: lastActive,
            windowLayer: layer,
            ownerPID: ownerPID,
            isStandardWindow: isStandardWindow
        )
    }

    /// 通过 AX API 查询指定窗口的最小化状态。需要辅助功能权限，失败时返回 nil。
    private static func axIsMinimized(pid: pid_t, windowTitle: String) -> Bool? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let wins = windowList as? [AXUIElement] else { return nil }
        for win in wins {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, title == windowTitle else { continue }
            var minimizedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                  let minimized = minimizedRef as? Bool else { return nil }
            return minimized
        }
        return nil
    }

    /// 读取 AX 窗口的位置与尺寸；读取失败时返回 nil。
    private func axFrame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

        guard let positionValue = positionRef, let sizeValue = sizeRef else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    /// 在同标题的候选窗口中选出与目标几何最接近的一个。
    ///
    /// 同标题多窗口（两个同名文档、两个同站点标签页）必须按几何消歧，
    /// 否则会激活到同应用的另一个窗口。返回候选下标；无法比较时返回 nil。
    static func selectClosestCandidate(frames: [CGRect?], targetFrame: CGRect) -> Int? {
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (index, frame) in frames.enumerated() {
            guard let frame else { continue }
            let distance = abs(frame.origin.x - targetFrame.origin.x)
                + abs(frame.origin.y - targetFrame.origin.y)
                + abs(frame.width - targetFrame.width)
                + abs(frame.height - targetFrame.height)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    /// 用 CGWindowID 匹配 AXUIElement，比标题匹配更可靠
    /// 如果精确匹配失败，返回 nil 而不是降级到第一个窗口（避免切换到错误窗口）
    private func axWindow(for model: WindowModel) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(model.ownerPID)
        var windowList: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
        guard result == .success, let wins = windowList as? [AXUIElement] else {
            Logger.warning("AXUIElementCopyAttributeValue failed for PID \(model.ownerPID): \(result.rawValue)")
            return nil
        }

        if wins.isEmpty {
            Logger.warning("No windows found for \(model.appName) (PID: \(model.ownerPID))")
            return nil
        }

        // 优先：通过 CGWindowID 精确匹配
        for win in wins {
            var cgWinID: CGWindowID = 0
            if _AXUIElementGetWindow(win, &cgWinID) == .success, cgWinID == model.id {
                Logger.debug("Matched window by CGWindowID: \(cgWinID)")
                return win
            }
        }

        // 次选：通过窗口标题匹配。同标题存在多个窗口时（如两个同名文档、两个同站点标签页），
        // 必须按位置/大小取最接近的一个，否则会激活到同应用的另一个窗口。
        if !model.windowTitle.isEmpty {
            let titleMatches = wins.filter { win in
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                return (titleRef as? String) == model.windowTitle
            }

            if titleMatches.count == 1 {
                Logger.debug("Matched window by title: \(model.windowTitle)")
                return titleMatches[0]
            }

            if titleMatches.count > 1 {
                let frames = titleMatches.map { axFrame(of: $0) }
                if let index = WindowManager.selectClosestCandidate(frames: frames, targetFrame: model.frame) {
                    Logger.warning("Multiple windows share title \"\(model.windowTitle)\"; matched by closest frame")
                    return titleMatches[index]
                }
            }
        }

        // 第三选择：通过窗口位置匹配（如果窗口标题不唯一）
        for win in wins {
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?

            AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &positionRef)
            AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)

            if let positionValue = positionRef, let sizeValue = sizeRef {
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

                // 检查位置和大小是否匹配
                if abs(position.x - model.frame.origin.x) < 5 &&
                   abs(position.y - model.frame.origin.y) < 5 &&
                   abs(size.width - model.frame.width) < 5 &&
                   abs(size.height - model.frame.height) < 5 {
                    Logger.debug("Matched window by position/size: \(position), \(size)")
                    return win
                }
            }
        }

        // 如果所有精确匹配都失败，打印警告并返回 nil（不再降级到第一个窗口）
        Logger.warning("No matching window found for: \(model.windowTitle), available windows: \(wins.count)")
        return nil
    }
}
