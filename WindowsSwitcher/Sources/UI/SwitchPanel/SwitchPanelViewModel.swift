import SwiftUI
import Combine

struct SameAppSwitchSession: Equatable {
    let bundleIdentifier: String
    var windowIDs: [CGWindowID]
    var selectedIndex: Int
}

/// 切换面板缩略图加载策略。
///
/// 面板中的每个窗口都必须进入缩略图加载队列；并发上限由 `PreviewGenerator`
/// 统一控制，不能在界面层截断窗口集合，否则排在后面的窗口会永久显示占位图。
enum SwitchPanelPreviewLoadPolicy {
    static func windowsToLoad(from windows: [WindowModel]) -> [WindowModel] {
        windows
    }
}

@MainActor
class SwitchPanelViewModel: ObservableObject {
    @Published var windows: [WindowModel] = []
    @Published var filteredWindows: [WindowModel] = []
    @Published var selectedIndex: Int = 0 {
        didSet {
            // 当索引改变时，同步更新 selectedWindowID
            if filteredWindows.indices.contains(selectedIndex) {
                selectedWindowID = filteredWindows[selectedIndex].id
            }
        }
    }
    @Published var selectedWindowID: CGWindowID?  // 使用窗口 ID 追踪选中状态
    @Published var searchText: String = "" {
        didSet { applyFilter() }
    }
    @Published var previewImages: [CGWindowID: NSImage] = [:]

    private let windowManager: WindowManagerProtocol
    private let previewGenerator: PreviewGenerator
    private let filterEngine: FilterEngine
    private let config = ConfigManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var activitySequence: [CGWindowID: UInt64] = [:]
    private(set) var sameAppSwitchSession: SameAppSwitchSession?

    init(windows: [WindowModel],
         windowManager: WindowManagerProtocol,
         previewGenerator: PreviewGenerator,
         filterEngine: FilterEngine) {
        self.windowManager = windowManager
        self.previewGenerator = previewGenerator
        self.filterEngine = filterEngine
        self.activitySequence = windowManager.activitySequenceSnapshot()
        self.windows = windows
        // 初始化选中状态
        if !windows.isEmpty {
            self.selectedWindowID = windows[0].id
        }
        applyFilter()
        setupNotifications()
    }

    // 刷新窗口列表，确保显示最新的活动窗口
    func refreshWindows() {
        let fresh = windowManager.getAllWindows(forceRefresh: true)
        activitySequence = windowManager.activitySequenceSnapshot()
        let scopedWindows = windowsScopedToActiveSession(fresh)
        reconcileSameAppSwitchSession(with: scopedWindows)
        updateWindows(scopedWindows)
    }

    // 更新窗口列表（已排序）
    func updateWindows(_ newWindows: [WindowModel]) {
        // 保持当前选中的窗口
        let previousSelectedID = selectedWindow?.id

        let freshIDs = Set(newWindows.map { $0.id })
        // 移除不存在的窗口的预览图，防止内存泄漏
        previewImages = previewImages.filter { freshIDs.contains($0.key) }

        windows = windowsScopedToActiveSession(newWindows)
        applyFilter()

        if sameAppSwitchSession != nil {
            selectSessionWindow()
            return
        }

        // 尝试保持之前选中的窗口
        if let previousID = previousSelectedID,
           let newIndex = filteredWindows.firstIndex(where: { $0.id == previousID }) {
            selectWindow(at: newIndex)
        }
    }

    // MARK: - 通知监听（响应全局快捷键）
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .switchHotKeyPressed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selectNext() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .reverseSwitchHotKeyPressed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.selectPrevious() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appSwitchHotKeyPressed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.switchWithinCurrentApp() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appSwitchReverseHotKeyPressed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.switchWithinCurrentAppReverse() }
            .store(in: &cancellables)
    }

    static func initialSelectionIndex(
        windowCount: Int,
        reversed: Bool,
        appSwitchMode: Bool,
        defaultSelectSecond: Bool
    ) -> Int {
        guard windowCount > 1 else { return 0 }
        if reversed { return windowCount - 1 }
        if appSwitchMode { return 1 }
        if defaultSelectSecond { return 1 }
        return 0
    }

    /// 按当前过滤列表的索引设置唯一选中窗口，并同步稳定窗口 ID。
    ///
    /// 所有界面入口都通过该方法更新选择，避免列表刷新后高亮索引与最终激活 ID 分离。
    @discardableResult
    func selectWindow(at index: Int) -> WindowModel? {
        guard filteredWindows.indices.contains(index) else {
            selectedIndex = 0
            selectedWindowID = nil
            return nil
        }
        let window = filteredWindows[index]
        selectedIndex = index
        selectedWindowID = window.id
        return window
    }

    func beginSameAppSwitchSession(bundleIdentifier: String, initialIndex: Int) {
        guard !bundleIdentifier.isEmpty else {
            endSameAppSwitchSession()
            return
        }

        let appWindows = windows.filter { $0.bundleIdentifier == bundleIdentifier }
        let orderedWindows = WindowOrdering().sort(
            appWindows,
            by: .recent,
            activitySequence: activitySequence
        )
        guard orderedWindows.count > 1 else {
            endSameAppSwitchSession()
            return
        }

        let clampedIndex = min(max(0, initialIndex), orderedWindows.count - 1)
        sameAppSwitchSession = SameAppSwitchSession(
            bundleIdentifier: bundleIdentifier,
            windowIDs: orderedWindows.map(\.id),
            selectedIndex: clampedIndex
        )
        windows = orderedWindows
        applyFilter()
        selectSessionWindow()
    }

    func advanceSameAppSwitchSession(reversed: Bool) {
        guard var session = sameAppSwitchSession, session.windowIDs.count > 1 else { return }
        let delta = reversed ? -1 : 1
        session.selectedIndex = (session.selectedIndex + delta + session.windowIDs.count) % session.windowIDs.count
        sameAppSwitchSession = session
        selectSessionWindow()
    }

    func reconcileSameAppSwitchSession(with availableWindows: [WindowModel]) {
        guard var session = sameAppSwitchSession else { return }
        let availableIDs = Set(
            availableWindows
                .filter { $0.bundleIdentifier == session.bundleIdentifier }
                .map(\.id)
        )
        let selectedID = session.windowIDs.indices.contains(session.selectedIndex)
            ? session.windowIDs[session.selectedIndex]
            : nil
        session.windowIDs.removeAll { !availableIDs.contains($0) }

        guard session.windowIDs.count > 1 else {
            endSameAppSwitchSession()
            return
        }
        if let selectedID, let index = session.windowIDs.firstIndex(of: selectedID) {
            session.selectedIndex = index
        } else {
            session.selectedIndex = min(session.selectedIndex, session.windowIDs.count - 1)
        }
        sameAppSwitchSession = session
    }

    func endSameAppSwitchSession() {
        sameAppSwitchSession = nil
    }

    func switchWithinCurrentApp() {
        advanceSameAppSwitchSession(reversed: false)
    }

    func switchWithinCurrentAppReverse() {
        advanceSameAppSwitchSession(reversed: true)
    }

    func applyFilter() {
        // 先保存当前选中的窗口 ID
        let previousSelectedID = selectedWindowID

        // T-063: 合并 filter+sort 为单次调用，减少中间数组分配
        let criteria = FilterCriteria(
            searchText: searchText,
            showOffScreen: config.config.behavior.showOffScreenWindows
        )
        let sortedWindows = filterEngine.filterAndSort(
            windows,
            criteria: criteria,
            order: config.config.behavior.sortOrder,
            activitySequence: activitySequence
        )
        if let session = sameAppSwitchSession {
            let sessionRank = Dictionary(uniqueKeysWithValues: session.windowIDs.enumerated().map { ($0.element, $0.offset) })
            filteredWindows = sortedWindows.sorted {
                (sessionRank[$0.id] ?? .max) < (sessionRank[$1.id] ?? .max)
            }
        } else {
            filteredWindows = sortedWindows
        }

        // 恢复选中状态：优先使用之前的窗口 ID
        if let prevID = previousSelectedID,
           let newIndex = filteredWindows.firstIndex(where: { $0.id == prevID }) {
            selectWindow(at: newIndex)
        } else {
            selectWindow(at: min(selectedIndex, max(0, filteredWindows.count - 1)))
        }

        loadVisiblePreviews()
    }

    private func windowsScopedToActiveSession(_ candidateWindows: [WindowModel]) -> [WindowModel] {
        guard let session = sameAppSwitchSession else { return candidateWindows }
        let frozenWindowIDs = Set(session.windowIDs)
        return candidateWindows.filter {
            $0.bundleIdentifier == session.bundleIdentifier && frozenWindowIDs.contains($0.id)
        }
    }

    private func selectSessionWindow() {
        guard let session = sameAppSwitchSession,
              session.windowIDs.indices.contains(session.selectedIndex) else { return }
        let windowID = session.windowIDs[session.selectedIndex]
        if let index = filteredWindows.firstIndex(where: { $0.id == windowID }) {
            selectWindow(at: index)
        }
    }

    // 记录当前选中窗口的应用（用于检测应用切换）
    private var currentSelectedAppBundleID: String?

    // 是否启用应用分组切换功能（通过配置控制）
    private var isAppGroupSwitchEnabled: Bool {
        // 从配置中读取排序方式，如果是 appGroup 则启用
        return config.config.behavior.sortOrder == .appGroup
    }

    func selectNext() {
        guard !filteredWindows.isEmpty else { return }
        // 直接计算下一个索引，不进行数组重排
        let nextIndex = (selectedIndex + 1) % filteredWindows.count
        let nextWindow = filteredWindows[nextIndex]

        // 操作日志：窗口选择
        Logger.windowSelect("Tab", windowInfo: "\(nextWindow.appName) - \(nextWindow.windowTitle)")

        selectWindow(at: nextIndex)

        // 刷新选中窗口的预览（实时获取最新内容）
        refreshSelectedWindowPreview()
    }

    func selectPrevious() {
        guard !filteredWindows.isEmpty else { return }
        // 直接计算上一个索引，不进行数组重排
        let prevIndex = (selectedIndex - 1 + filteredWindows.count) % filteredWindows.count
        let prevWindow = filteredWindows[prevIndex]

        // 操作日志：窗口选择
        Logger.windowSelect("Shift+Tab", windowInfo: "\(prevWindow.appName) - \(prevWindow.windowTitle)")

        selectWindow(at: prevIndex)

        // 刷新选中窗口的预览（实时获取最新内容）
        refreshSelectedWindowPreview()
    }

    /// 上方向键：移动到上一行同列位置
    func selectUp() {
        guard !filteredWindows.isEmpty else { return }

        // 获取列数
        let columnCount = getColumnCount()
        guard columnCount > 0 else { return }

        let currentRow = selectedIndex / columnCount
        let currentCol = selectedIndex % columnCount

        if currentRow == 0 {
            // 已在第一行，不做处理
            return
        }

        // 计算上一行同列位置
        let targetIndex = (currentRow - 1) * columnCount + currentCol

        // 边界检查：确保目标索引有效
        if targetIndex < filteredWindows.count {
            selectWindow(at: targetIndex)
            // 刷新选中窗口的预览（实时获取最新内容）
            refreshSelectedWindowPreview()
        }
    }

    /// 下方向键：移动到下一行同列位置
    func selectDown() {
        guard !filteredWindows.isEmpty else { return }

        // 获取列数
        let columnCount = getColumnCount()
        guard columnCount > 0 else { return }

        let totalRows = (filteredWindows.count + columnCount - 1) / columnCount
        let currentRow = selectedIndex / columnCount
        let currentCol = selectedIndex % columnCount

        if currentRow >= totalRows - 1 {
            // 已在最后一行，不做处理
            return
        }

        // 计算下一行同列位置
        let targetIndex = (currentRow + 1) * columnCount + currentCol

        // 边界检查：确保目标索引有效
        if targetIndex < filteredWindows.count {
            selectWindow(at: targetIndex)
            // 刷新选中窗口的预览（实时获取最新内容）
            refreshSelectedWindowPreview()
        }
    }

    /// 获取当前列数
    private func getColumnCount() -> Int {
        let previewSize = ConfigManager.shared.config.appearance.previewSize
        let itemWidth = previewSize.itemDimensions.width
        let maxPanelWidth: CGFloat = 1400

        var columnCount: Int
        if ConfigManager.shared.config.appearance.switcherColumns > 0 {
            columnCount = ConfigManager.shared.config.appearance.switcherColumns
        } else {
            columnCount = max(3, min(8, Int((maxPanelWidth - 24) / (itemWidth + 16))))
        }
        return columnCount
    }

    /// 刷新选中窗口的预览（使用实时预览，不使用缓存）
    func refreshSelectedWindowPreview() {
        guard let windowID = selectedWindowID,
              let window = filteredWindows.first(where: { $0.id == windowID }) else { return }

        Task(priority: .userInitiated) {
            let size = config.config.appearance.previewSize.dimensions
            let previewSize = CGSize(width: size.width, height: size.height)

            // 使用实时预览，不使用缓存
            if let image = await previewGenerator.generateRealtimePreview(for: window, size: previewSize) {
                await MainActor.run {
                    self.previewImages[windowID] = image
                }
            }
        }
    }

    func activateSelected() {
        // 同应用会话在提交激活前做一次最终协调，跳过会话期间已关闭的窗口。
        if sameAppSwitchSession != nil {
            refreshWindows()
        }

        // 优先使用 selectedWindowID 查找，更可靠
        guard let window = selectedWindow else {
            Logger.warning("activateSelected: selectedWindow is nil")
            Logger.windowActivate("未知窗口", result: "失败 - selectedWindow 为 nil")
            return
        }
        Logger.windowActivate("\(window.appName) - \(window.windowTitle)", result: "开始激活")
        Logger.info("activateSelected: activating \(window.appName) (PID: \(window.ownerPID), Title: \(window.windowTitle))")
        // 激活前先刷新窗口缓存
        windowManager.refreshCache()
        windowManager.activateWindow(window)
    }

    /// 通过窗口 ID 直接激活（避免索引问题）
    func activateWindowByID(_ windowID: CGWindowID) {
        // 找到对应的窗口
        guard let window = filteredWindows.first(where: { $0.id == windowID }) else {
            Logger.warning("activateWindowByID: window not found, id: \(windowID)")
            return
        }
        Logger.windowActivate("\(window.appName) - \(window.windowTitle)", result: "通过ID激活")
        windowManager.activateWindow(window)
    }

    func closeWindow(_ window: WindowModel) {
        // BUG-006: 先乐观移除，200ms 后从系统重新获取确认
        windowManager.closeWindow(window)
        windows.removeAll { $0.id == window.id }
        applyFilter()
        refreshWindowsAfterDelay()
    }

    func minimizeWindow(_ window: WindowModel) {
        windowManager.minimizeWindow(window)
        windows.removeAll { $0.id == window.id }
        applyFilter()
        refreshWindowsAfterDelay()
    }

    func hideWindow(_ window: WindowModel) {
        windowManager.hideWindow(window)
        windows.removeAll { $0.id == window.id }
        applyFilter()
        refreshWindowsAfterDelay()
    }

    private func refreshWindowsAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms (从300ms减少，大幅提升响应速度)
            refreshWindows()
        }
    }

    var selectedWindow: WindowModel? {
        // 优先使用 selectedWindowID 查找，更可靠
        if let windowID = selectedWindowID {
            return filteredWindows.first { $0.id == windowID }
        }
        // 降级：使用 selectedIndex
        return filteredWindows.indices.contains(selectedIndex) ? filteredWindows[selectedIndex] : nil
    }

    private func loadVisiblePreviews() {
        // 全部可见窗口都必须进入加载队列；并发压力由 PreviewGenerator 内部控制。
        let windowsToLoad = SwitchPanelPreviewLoadPolicy.windowsToLoad(from: filteredWindows)
        let sizeConfig = config.config.appearance.previewSize.dimensions
        let previewSize = CGSize(width: sizeConfig.width, height: sizeConfig.height)
        let previewGenerator = previewGenerator

        Task(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for window in windowsToLoad {
                    group.addTask {
                        // 1. 立即显示缓存图（无论新旧，避免空白）
                        if let cached = await previewGenerator.getCachedPreview(for: window.id) {
                            await MainActor.run {
                                self?.previewImages[window.id] = cached
                            }
                        }
                        // 2. 异步强制生成最新截图，确保内容实时
                        if let image = await previewGenerator.generateRealtimePreview(for: window, size: previewSize) {
                            await MainActor.run {
                                self?.previewImages[window.id] = image
                            }
                        }
                    }
                }
            }
        }
    }

    // 异步加载单个预览（非阻塞）
    private func loadPreviewAsync(for window: WindowModel) async {
        // 如果已经有缓存，跳过
        if previewImages[window.id] != nil { return }

        // 使用适中的预览尺寸
        let size = CGSize(width: 200, height: 112)

        // 直接使用 PreviewGenerator 生成预览（内部已包含缓存逻辑）
        if let image = await self.previewGenerator.generatePreview(for: window, size: size) {
            await MainActor.run {
                self.previewImages[window.id] = image
            }
        }
    }

    // 用于控制并发预览生成任务
    private var previewLoadTasks: [CGWindowID: Task<Void, Never>] = [:]

    private func loadPreview(for window: WindowModel) {
        // 如果已经在加载中，取消之前的任务
        previewLoadTasks[window.id]?.cancel()

        let task = Task { [weak self] in
            guard let self = self else { return }

            // 使用适中的预览尺寸
            let size = CGSize(width: 200, height: 112)

            // 直接使用 PreviewGenerator 生成预览（内部已包含缓存逻辑）
            if let image = await self.previewGenerator.generatePreview(for: window, size: size) {
                await MainActor.run {
                    self.previewImages[window.id] = image
                    self.previewLoadTasks.removeValue(forKey: window.id)
                }
            }

            // 预加载相邻窗口
            await self.prefetchAdjacentPreviews(from: window)
        }

        previewLoadTasks[window.id] = task
    }

    /// 延迟加载预览（让 UI 先完成渲染）
    private func loadPreviewDelayed(for window: WindowModel) {
        // 如果已经有缓存，跳过
        if previewImages[window.id] != nil { return }

        // 延迟 16ms（约一帧）后再加载，避免阻塞切换
        Task {
            try? await Task.sleep(nanoseconds: 16_000_000)  // 16ms
            await MainActor.run {
                self.loadPreview(for: window)
            }
        }
    }

    /// 预加载相邻窗口的预览（向前预加载2个，向后预加载1个）
    private func prefetchAdjacentPreviews(from window: WindowModel) async {
        guard let currentIndex = filteredWindows.firstIndex(where: { $0.id == window.id }) else { return }

        // 预加载范围：当前索引-2 到 当前索引+1
        let startIndex = max(0, currentIndex - 2)
        let endIndex = min(filteredWindows.count - 1, currentIndex + 1)

        for index in startIndex...endIndex {
            guard index != currentIndex else { continue }  // 跳过当前窗口
            let windowToPreload = filteredWindows[index]
            
            // 只预加载尚未在内存中的窗口
            guard previewImages[windowToPreload.id] == nil else { continue }

            let previewGenerator = previewGenerator
            let windowID = windowToPreload.id
            // 低优先级预加载（不阻塞主线程）
            Task(priority: .background) { [weak self, previewGenerator, windowToPreload] in
                let size = CGSize(width: 124, height: 70)  // 小尺寸预览
                // PreviewGenerator 内部已包含缓存逻辑
                if let img = await previewGenerator.generatePreview(for: windowToPreload, size: size) {
                    self?.previewImages[windowID] = img
                }
            }
        }
    }
}
