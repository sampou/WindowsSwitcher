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

    // 应用信息缓存（PID -> (bundleID, icon, isHidden)）
    private var appInfoCache: [pid_t: (bundleIdentifier: String, icon: NSImage, isHidden: Bool)] = [:]

    // 线程安全锁：保护窗口缓存、活动序号、焦点窗口与缓存版本
    // 后台预取线程和主线程并发读写这些 Dictionary 会触发 EXC_BAD_ACCESS
    private let stateLock = NSLock()

    // 进程内窗口活动序号（不跨启动持久化）
    private let activitySequence = WindowActivitySequence()

    // 焦点窗口轮询定时器（用于监听同一应用内的窗口切换，如 Command+`）
    private var focusPollingTimer: Timer?
    // 低频主动枚举，用于发现未伴随应用激活通知的外部窗口创建/销毁。
    private var windowLifecyclePoller: WindowLifecyclePoller?
    private var lastFocusedWindowID: CGWindowID?

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
            return result
        }

        let axFilteringEnabled = axFilterCircuitBreaker.isEnabled(now: now)
        // AX 是同步跨进程调用。采集必须在 stateLock 外完成，避免目标应用无响应时
        // 阻塞缓存读写和快捷键触发的同步刷新。
        stateLock.unlock()

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let axCollection = axFilteringEnabled
            ? collectNonStandardAccessibilityWindows(for: AXWindowFilteringPolicy.candidateOwnerPIDs(in: list))
            : .skipped

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
        let windows = WindowIDDeduplicator.unique(list.compactMap {
            buildWindowModel(from: $0, nonStandardAccessibilityWindowIDs: axCollection.nonStandardWindowIDs)
        })
        let windowEvents = WindowSnapshotReconciler.events(
            previous: windowCache,
            current: windows,
            hasBaseline: hasWindowSnapshotBaseline
        )
        let currentWindowIDs = Set(windows.map(\.id))
        let staleWindowIDs = Set(windowCache.keys).subtracting(currentWindowIDs)

        for window in windows {
            windowCache[window.id] = window
            recordFirstObservationLocked(windowID: window.id)
        }
        staleWindowIDs.forEach { windowCache.removeValue(forKey: $0) }
        removeActivityLocked(windowIDs: staleWindowIDs)
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

    /// 面板打开前同步记录指定应用的真实焦点窗口。
    @discardableResult
    func recordFocusedWindowActivity(pid: pid_t) -> CGWindowID? {
        guard let windowID = getFocusedWindowID(pid: pid) else { return nil }
        stateLock.lock()
        recordActivityLocked(windowID: windowID)
        lastFocusedWindowID = windowID
        stateLock.unlock()
        return windowID
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
                // 如果无法获取焦点窗口，更新该应用最新的窗口（降级方案）
                let appWindows = self.windowCache.values.filter { $0.ownerPID == pid }
                let activitySequence = self.activitySequence.snapshot()
                self.stateLock.unlock()

                let orderedAppWindows = WindowOrdering().sort(
                    appWindows,
                    by: .recent,
                    activitySequence: activitySequence
                )
                if let first = orderedAppWindows.first {
                    var model = first
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
                    self.stateLock.lock()
                    guard self.windowCache[model.id] != nil else {
                        self.stateLock.unlock()
                        return
                    }
                    self.windowCache[model.id] = model
                    self.recordActivityLocked(windowID: model.id)
                    self.lastFocusedWindowID = model.id
                    self.stateLock.unlock()
                    Logger.debug("==> Fallback: Updated lastActiveTime for newest window: \(model.windowTitle)")
                }
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

        guard let focusedWindowID = getFocusedWindowID(pid: pid) else { return }

        let now = Date()
        stateLock.lock()
        guard focusedWindowID != lastFocusedWindowID else {
            stateLock.unlock()
            return
        }
        lastFocusedWindowID = focusedWindowID

        guard var model = windowCache[focusedWindowID] else {
            stateLock.unlock()
            return
        }
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
        windowCache[focusedWindowID] = model
        recordActivityLocked(windowID: focusedWindowID)
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

        // 使用应用信息缓存，避免重复调用 NSRunningApplication
        // 线程安全：由 getAllWindows 的 stateLock 保护
        let appInfo: (bundleIdentifier: String, icon: NSImage, isHidden: Bool)
        if let cached = appInfoCache[ownerPID] {
            appInfo = cached
        } else {
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let bundleID = app?.bundleIdentifier ?? ""
            let icon = app?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            let isHidden = app?.isHidden ?? false
            appInfo = (bundleID, icon, isHidden)
            appInfoCache[ownerPID] = appInfo
        }

        // BUG-001: 通过 AX API 读取最小化状态，降级方案：isOnScreen=false && layer==0
        // 禁用 AX API 调用以提升性能，使用降级方案
        let isMinimized = !isOnScreen && layer == 0

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

        // 次选：通过窗口标题精确匹配
        for win in wins {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title == model.windowTitle {
                Logger.debug("Matched window by title: \(title)")
                return win
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
