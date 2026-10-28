import Foundation
import AppKit
import Combine
import ApplicationServices

/// 智能目录粘贴协调器。
///
/// 职责：
/// - 组装事件 tap、上下文监控、适配器注册表与导航执行器；
/// - 维护拦截决策快照，事件 tap 回调中只读取快照；
/// - 在导航失败时给出非阻塞提示。
///
/// 原则：一切不确定情况一律放行原始 ⌘V（fail-open）。
final class SmartPasteCoordinator: ObservableObject {

    enum Status: Equatable {
        case disabled
        case waitingForPermission
        case active
        case degraded(String)
    }

    @Published private(set) var status: Status = .disabled

    /// 切换面板是否可见。由 AppDelegate 注入；面板可见时不得拦截 ⌘V。
    var isSelfPanelVisible: (() -> Bool)?

    private let parser = ClipboardPathParser()
    private let engine = PasteDecisionEngine()
    private let feedback = FeedbackPresenter()
    private let eventTap = SmartPasteEventTap()
    private let store = SnapshotStore()
    private let rightClickNavigator = RightClickNavigator()

    private let workQueue: DispatchQueue
    private let monitor: AXContextMonitor
    private let registry: AdapterRegistry
    private let navigator: NativePanelNavigator

    private var refreshTimer: DispatchSourceTimer?
    private var config = SmartPasteConfig()
    private var isRunning = false
    private var clipboardChangeCount = -1
    private var cachedClipboard: ClipboardPathResult = .notApplicable
    /// 上一次落盘的决策上下文签名，用于只在状态变化时记录
    private var lastDecisionSignature = ""
    /// 上一次提示"按回车进入目录"的时间
    private var lastEnterHintAt: Date?

    /// 右键跳转所需的缓存上下文（由后台刷新维护，避免在事件回调里做 AX 查询）。
    private var cachedPathField: AXUIElement?
    private var cachedFocusedWindow: AXUIElement?
    private var cachedProcessID: pid_t?
    private var cachedBundleID: String?
    private var cachedAdapterConfidence: AdapterConfidence?
    /// 当前窗口是否存在文件列表（用于识别"看起来像文件面板"的自定义面板）
    private var cachedHasFileList = false

    /// 快照刷新节奏（秒）。事件驱动之外的后台兜底刷新。
    private static let refreshInterval: TimeInterval = 0.5

    init() {
        let queue = DispatchQueue(label: "com.moeasy.windowsswitcher.smartpaste.worker",
                                  qos: .userInitiated)
        let navigator = NativePanelNavigator()
        self.workQueue = queue
        self.navigator = navigator
        self.monitor = AXContextMonitor(queue: queue)
        self.registry = AdapterRegistry(adapters: [NativePanelAdapter(navigator: navigator)])
    }

    // MARK: - 生命周期

    func start(config: SmartPasteConfig) {
        self.config = config

        guard config.enabled else {
            stop()
            updateStatus(.disabled)
            return
        }

        guard AXIsProcessTrusted() else {
            stop()
            updateStatus(.waitingForPermission)
            Logger.warning("智能粘贴: 缺少辅助功能权限，功能未启用")
            return
        }

        guard !isRunning else {
            return
        }
        isRunning = true

        monitor.onChange = { [weak self] in
            self?.scheduleRefresh()
        }
        monitor.start()

        eventTap.resolveSnapshot = { [weak self] in
            self?.validSnapshot()
        }
        eventTap.onIntercept = { [weak self] request in
            self?.handleIntercept(request)
        }
        eventTap.onDisabled = { [weak self] count in
            self?.handleTapDisabled(count)
        }
        eventTap.onRightClick = { [weak self] point in
            self?.handleRightClick(at: point) ?? false
        }

        do {
            try eventTap.start()
        } catch {
            isRunning = false
            updateStatus(.degraded("event-tap-failed"))
            Logger.error("智能粘贴: 无法创建 Event Tap，功能未启用")
            return
        }

        startRefreshTimer()
        updateStatus(.active)
        Logger.operation("智能粘贴", detail: "功能已启动")
        scheduleRefresh()
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        eventTap.stop()
        monitor.stop()
        isRunning = false
        store.update(snapshot: .empty(), frontmostProcessID: nil)
    }

    /// 配置变更时重新应用。
    func updateConfig(_ config: SmartPasteConfig) {
        guard config != self.config else { return }
        let wasEnabled = self.config.enabled
        self.config = config

        if config.enabled {
            if !wasEnabled {
                start(config: config)
            } else {
                // 运行中只调整超时等参数，无需重建事件 tap。
                Logger.debug("智能粘贴: 配置已更新")
            }
        } else if wasEnabled {
            stop()
            updateStatus(.disabled)
            Logger.operation("智能粘贴", detail: "功能已关闭")
        }
    }

    // MARK: - 快照

    /// 生成可供事件 tap 回调读取的快照；回调中只做常数级校验。
    private func validSnapshot() -> PasteEligibilitySnapshot? {
        let snapshot = store.currentSnapshot

        guard snapshot.request != nil else { return nil }
        guard Date() < snapshot.expiresAt else { return nil }
        guard store.currentFrontmostProcessID == snapshot.processID else { return nil }
        guard store.currentGeneration == snapshot.focusGeneration else { return nil }
        guard NSPasteboard.general.changeCount == snapshot.clipboardChangeCount else { return nil }

        return snapshot
    }

    private func scheduleRefresh() {
        workQueue.async { [weak self] in
            self?.performRefresh()
        }
    }

    /// 刷新决策快照。全部辅助功能与文件系统访问都在工作队列上完成。
    private func performRefresh() {
        guard isRunning else { return }

        // 权限可能在运行期间被撤销。
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePermissionLost()
            }
            return
        }

        let context = monitor.currentContext()

        // 前台应用变化：焦点代数自增，旧快照立即失效。
        let generation: UInt64
        if context.processID != store.currentFrontmostProcessID {
            generation = store.bumpGeneration()
        } else {
            generation = store.currentGeneration
        }

        // 剪贴板变化：重新解析（只读，不写入）。
        if context.clipboardChangeCount != clipboardChangeCount {
            clipboardChangeCount = context.clipboardChangeCount
            cachedClipboard = parser.parse()
        }

        var request: NavigationRequest?
        var denyReason = PassThroughReason.focusUnknown
        var adapterConfidence: AdapterConfidence?
        var focusRole: String?

        let selfActive = isSelfApplicationActive()
        let panelVisible = isSelfPanelVisibleNow()

        if let processID = context.processID,
           let bundleID = context.bundleID,
           let window = context.focusedWindow,
           !selfActive,
           !panelVisible {
            let dialogContext = DialogContext(processID: processID,
                                              bundleID: bundleID,
                                              window: window,
                                              focusedElement: context.focusedElement,
                                              kind: .openFile)

            let focus = FocusClassifier.classify(role: context.focusedRole)
            focusRole = context.focusedRole
            adapterConfidence = registry.match(dialogContext)?.confidence
            let decision = engine.decide(PasteDecisionEngine.Input(clipboard: cachedClipboard,
                                                                    focus: focus,
                                                                    adapterConfidence: adapterConfidence))

            switch decision {
            case .allow:
                if let directory = cachedClipboard.directoryURL {
                    request = NavigationRequest(directory: directory,
                                                processID: processID,
                                                bundleID: bundleID,
                                                focusGeneration: generation,
                                                clipboardChangeCount: clipboardChangeCount)
                    denyReason = .noAdapter
                } else {
                    denyReason = .clipboardNotPath
                }
            case .deny(let reason):
                denyReason = reason
            }
        } else if selfActive {
            denyReason = .selfApplication
        } else if panelVisible {
            denyReason = .panelVisible
        }

        let snapshot = PasteEligibilitySnapshot(request: request,
                                                processID: context.processID ?? 0,
                                                focusGeneration: generation,
                                                clipboardChangeCount: clipboardChangeCount)
        store.update(snapshot: snapshot, frontmostProcessID: context.processID)

        // 缓存右键跳转所需的上下文。这里会做一次辅助功能遍历，
        // 但只发生在后台刷新中，不会占用事件回调的时间。
        cachedAdapterConfidence = adapterConfidence
        if let window = context.focusedWindow, !selfActive, !panelVisible {
            cachedFocusedWindow = window
            cachedProcessID = context.processID
            cachedBundleID = context.bundleID
            cachedPathField = DialogPathFieldLocator.locate(in: window)?.element
            cachedHasFileList = SmartAXReader.firstDescendant(of: window) { element in
                guard let role = SmartAXReader.role(of: element) else {
                    return false
                }
                return FocusClassifier.browserRoles.contains(role)
            } != nil
        } else {
            cachedFocusedWindow = nil
            cachedPathField = nil
            cachedHasFileList = false
        }

        // 检测"目录路径已被原生粘贴进文件名框"：此时再按一次回车即可进入该目录。
        // 这条提示对所有第三方自定义面板都通用，且不干预任何原生行为。
        if let directory = cachedClipboard.directoryURL,
           let focusedValue = context.focusedValue,
           cachedHasFileList,
           matchesPath(focusedValue, directory: directory) {
            showEnterHintIfNeeded()
        }

        // 决策上下文落盘：只在状态变化时记录，便于事后复盘"为什么没有跳转"。
        // 之前这些信息只写进 debug 日志，既不落文件也不进持久化日志，事后无法追溯。
        let signature = decisionSignature(processID: context.processID,
                                          bundleID: context.bundleID,
                                          focusRole: focusRole,
                                          adapterConfidence: adapterConfidence,
                                          decision: request == nil ? "放行(\(denyReason.rawValue))" : "拦截跳转")
        if signature != lastDecisionSignature {
            lastDecisionSignature = signature
            Logger.operation("智能粘贴", detail: "上下文变化", result: signature)
        }
    }

    /// 生成可读的决策上下文描述。
    private func decisionSignature(processID: pid_t?,
                                   bundleID: String?,
                                   focusRole: String?,
                                   adapterConfidence: AdapterConfidence?,
                                   decision: String) -> String {
        let appName = processID.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "未知应用"
        let bundle = bundleID ?? "无"
        let focus = focusRole ?? "无焦点"
        let clipboard = clipboardStateName(cachedClipboard)
        let adapter: String
        switch adapterConfidence {
        case .confirmed: adapter = "已识别"
        case .uncertain: adapter = "疑似"
        case .unsupported: adapter = "不支持"
        case nil: adapter = "无匹配"
        }
        return "应用=\(appName)(\(bundle)) 焦点=\(focus) 剪贴板=\(clipboard) 适配器=\(adapter) 决策=\(decision)"
    }

    /// 剪贴板状态的可读描述（不包含路径，避免泄露目录信息）。
    private func clipboardStateName(_ result: ClipboardPathResult) -> String {
        switch result {
        case .directory: return "目录"
        case .file: return "文件"
        case .missing: return "路径无效"
        case .notApplicable: return "非路径"
        }
    }

    /// 判断输入框里的文本是否就是目标目录路径（允许尾部斜杠与 `~` 写法）。
    func matchesPath(_ text: String, directory: URL) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        let path = directory.standardizedFileURL.path
        if trimmed == path {
            return true
        }
        if trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath == path
        }
        return false
    }

    /// 提示用户"再按一次回车进入目录"。相同提示 10 秒内只出现一次。
    private func showEnterHintIfNeeded() {
        let now = Date()
        if let last = lastEnterHintAt, now.timeIntervalSince(last) < 10 {
            return
        }
        lastEnterHintAt = now
        feedback.show(message: L10n.text("路径已填入，按 ⇩（Return）键进入目录"), style: .info)
    }

    // MARK: - 右键跳转

    /// 处理右键。
    ///
    /// 只有在「剪贴板是目录」且「当前窗口是文件面板（存在路径显示框或已被适配器识别）」时
    /// 才会跳转，避免在普通窗口里右键也触发动作。
    ///
    /// - Returns: 是否吞掉该右键（吞掉后系统不再弹出原生右键菜单）。
    private func handleRightClick(at point: CGPoint) -> Bool {
        guard config.rightClickJumpEnabled else { return false }
        guard let directory = cachedClipboard.directoryURL else { return false }
        guard let processID = cachedProcessID,
              let bundleID = cachedBundleID,
              cachedFocusedWindow != nil else {
            return false
        }

        let hasPathField = cachedPathField != nil
        let isNativePanel = cachedAdapterConfidence == .confirmed
        guard hasPathField || isNativePanel else {
            // 自定义面板（第三方应用自绘）：给出明确反馈，而不是让右键毫无反应。
            if cachedHasFileList {
                reportFailure("该应用使用自定义文件面板，暂不支持智能跳转")
            }
            return false
        }

        let request = NavigationRequest(directory: directory,
                                        processID: processID,
                                        bundleID: bundleID,
                                        focusGeneration: store.currentGeneration,
                                        clipboardChangeCount: clipboardChangeCount)

        Task { [weak self] in
            await self?.performRightClickNavigation(request)
        }

        return config.suppressSystemContextMenu
    }

    private func performRightClickNavigation(_ request: NavigationRequest) async {
        guard let context = currentDialogContext(for: request) else {
            reportFailure("无法定位目标窗口，已放弃跳转")
            return
        }

        let outcome = await rightClickNavigator.navigate(to: request.directory,
                                                         in: context,
                                                         timeout: config.navigationTimeout,
                                                         allowKeySynthesis: config.suppressSystemContextMenu)

        if outcome.navigated {
            Logger.operation("智能粘贴", detail: "右键跳转到目标目录", result: outcome.strategy)
        } else {
            reportFailure(failureMessage(for: outcome.error))
        }
    }

    private func startRefreshTimer() {        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + Self.refreshInterval,
                       repeating: Self.refreshInterval,
                       leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            self?.performRefresh()
        }
        timer.resume()
        refreshTimer = timer
    }

    // MARK: - 拦截与导航

    /// 事件 tap 已吞下 ⌘V；执行导航前再做一次校验。
    private func handleIntercept(_ request: NavigationRequest) {
        guard store.currentFrontmostProcessID == request.processID else {
            Logger.info("智能粘贴: 拦截后前台进程已变化，放弃导航")
            return
        }
        guard NSPasteboard.general.changeCount == request.clipboardChangeCount else {
            Logger.info("智能粘贴: 拦截后剪贴板已变化，放弃导航")
            return
        }

        Task { [weak self] in
            await self?.performNavigation(request)
        }
    }

    private func performNavigation(_ request: NavigationRequest) async {
        guard let context = currentDialogContext(for: request) else {
            reportFailure("无法定位目标窗口，已放弃跳转")
            return
        }

        let outcome = await navigator.navigate(to: request.directory,
                                               in: context,
                                               timeout: config.navigationTimeout)

        if outcome.navigated {
            Logger.operation("智能粘贴",
                             detail: "已跳转到目标目录",
                             result: outcome.verified ? "已校验目录" : "无法确认目录")
        } else {
            reportFailure(failureMessage(for: outcome.error))
        }
    }

    /// 重新读取目标应用当前聚焦的窗口作为导航上下文。
    private func currentDialogContext(for request: NavigationRequest) -> DialogContext? {
        let app = AXUIElementCreateApplication(request.processID)
        guard let window = SmartAXReader.elementAttribute(app, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        let focused = SmartAXReader.elementAttribute(app, kAXFocusedUIElementAttribute as CFString)
        return DialogContext(processID: request.processID,
                             bundleID: request.bundleID,
                             window: window,
                             focusedElement: focused,
                             kind: .openFile)
    }

    // MARK: - 降级处理

    private func handleTapDisabled(_ count: Int) {
        Logger.warning("智能粘贴: Event Tap 被系统禁用（累计 \(count) 次），已尝试重新启用")
        if count >= 3 {
            stop()
            updateStatus(.degraded("tap-disabled"))
            reportFailure("系统禁用了键盘监听，已暂时停用智能跳转")
        }
    }

    private func handlePermissionLost() {
        stop()
        updateStatus(.waitingForPermission)
        Logger.warning("智能粘贴: 辅助功能权限已撤销，功能已停用")
    }

    private func reportFailure(_ message: String) {
        Logger.warning("智能粘贴: \(message)")
        guard config.showFailureToast else { return }
        feedback.show(message: message)
    }

    private func failureMessage(for error: NavigationError?) -> String {
        switch error {
        case .invalidDirectory, .directoryNotAccessible:
            return "无法跳转到目录：目标目录不存在或当前无法访问"
        case .targetFieldNotFound:
            return "无法跳转到目录：未找到目标路径输入框"
        case .axOperationFailed:
            return "无法跳转到目录：目标窗口操作失败"
        case .keyboardSynthesisFailed:
            return "无法跳转到目录：键盘事件发送失败"
        case .timeout:
            return "无法跳转到目录：操作超时，可手动按 ⇧⌘G 前往文件夹"
        case .focusChanged:
            return "已放弃跳转：窗口焦点已变化"
        case .unsupportedDialog, .permissionDenied, .verificationFailed:
            return "无法跳转到目录：当前窗口不支持智能跳转"
        case nil:
            return "无法跳转到目录：当前窗口不支持智能跳转"
        }
    }

    // MARK: - 状态

    private func isSelfApplicationActive() -> Bool {
        let ownBundleID = Bundle.main.bundleIdentifier
        guard let ownBundleID else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleID
    }

    private func isSelfPanelVisibleNow() -> Bool {
        guard let provider = isSelfPanelVisible else { return false }
        if Thread.isMainThread {
            return provider()
        }
        return DispatchQueue.main.sync { provider() }
    }

    private func updateStatus(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = status
        }
    }
}

/// 快照存储：事件 tap 回调线程与工作队列之间的唯一共享状态。
private final class SnapshotStore {

    private let lock = NSLock()
    private var snapshot: PasteEligibilitySnapshot = .empty()
    private var generation: UInt64 = 0
    private var frontmostProcessID: pid_t?

    var currentSnapshot: PasteEligibilitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var currentFrontmostProcessID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return frontmostProcessID
    }

    @discardableResult
    func bumpGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func update(snapshot: PasteEligibilitySnapshot, frontmostProcessID: pid_t?) {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
        self.frontmostProcessID = frontmostProcessID
    }
}
