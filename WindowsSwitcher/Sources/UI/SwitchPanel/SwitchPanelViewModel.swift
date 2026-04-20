import SwiftUI
import Combine

@MainActor
class SwitchPanelViewModel: ObservableObject {
    @Published var windows: [WindowModel] = []
    @Published var filteredWindows: [WindowModel] = []
    @Published var selectedIndex: Int = 0
    @Published var searchText: String = "" {
        didSet { applyFilter() }
    }
    @Published var previewImages: [CGWindowID: NSImage] = [:]

    private let windowManager: WindowManagerProtocol
    private let previewGenerator: PreviewGenerator
    private let filterEngine: FilterEngine
    private let config = ConfigManager.shared
    private var cancellables = Set<AnyCancellable>()

    init(windows: [WindowModel],
         windowManager: WindowManagerProtocol,
         previewGenerator: PreviewGenerator,
         filterEngine: FilterEngine) {
        self.windowManager = windowManager
        self.previewGenerator = previewGenerator
        self.filterEngine = filterEngine
        self.windows = windows
        applyFilter()
        setupNotifications()
    }

    // 刷新窗口列表，确保显示最新的活动窗口
    func refreshWindows() {
        let fresh = windowManager.getAllWindows()
        updateWindows(fresh)
    }

    // 更新窗口列表（已排序）
    func updateWindows(_ newWindows: [WindowModel]) {
        // 保持当前选中的窗口
        let previousSelectedID = selectedWindow?.id

        let freshIDs = Set(newWindows.map { $0.id })
        // 移除不存在的窗口的预览图，防止内存泄漏
        previewImages = previewImages.filter { freshIDs.contains($0.key) }

        windows = newWindows
        applyFilter()

        // 尝试保持之前选中的窗口
        if let previousID = previousSelectedID,
           let newIndex = filteredWindows.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = newIndex
        }
    }

    // MARK: - 通知监听（响应全局快捷键）
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .switchHotKeyPressed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let t0 = CFAbsoluteTimeGetCurrent()
                self?.selectNext()
                Logger.info("=== notification -> selectNext took: \((CFAbsoluteTimeGetCurrent() - t0)*1000)ms ===")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .reverseSwitchHotKeyPressed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let t0 = CFAbsoluteTimeGetCurrent()
                self?.selectPrevious()
                Logger.info("=== notification -> selectPrevious took: \((CFAbsoluteTimeGetCurrent() - t0)*1000)ms ===")
            }
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

    func switchWithinCurrentApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName else { return }
        let appWindows = windows.filter { $0.appName == frontApp }
        guard appWindows.count > 1 else { return }
        if let currentIdx = appWindows.firstIndex(where: { $0.id == selectedWindow?.id }) {
            let nextIdx = (currentIdx + 1) % appWindows.count
            if let globalIdx = filteredWindows.firstIndex(where: { $0.id == appWindows[nextIdx].id }) {
                selectedIndex = globalIdx
            }
        }
    }

    func switchWithinCurrentAppReverse() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName else { return }
        let appWindows = windows.filter { $0.appName == frontApp }
        guard appWindows.count > 1 else { return }
        if let currentIdx = appWindows.firstIndex(where: { $0.id == selectedWindow?.id }) {
            let prevIdx = (currentIdx - 1 + appWindows.count) % appWindows.count
            if let globalIdx = filteredWindows.firstIndex(where: { $0.id == appWindows[prevIdx].id }) {
                selectedIndex = globalIdx
            }
        }
    }

    func applyFilter() {
        // T-063: 合并 filter+sort 为单次调用，减少中间数组分配
        let criteria = FilterCriteria(
            searchText: searchText,
            showMinimized: config.config.behavior.showMinimizedWindows,
            showHidden: config.config.behavior.showHiddenWindows
        )
        filteredWindows = filterEngine.filterAndSort(windows, criteria: criteria,
                                                     order: config.config.behavior.sortOrder)
        selectedIndex = min(selectedIndex, max(0, filteredWindows.count - 1))
        loadVisiblePreviews()
    }

    // 记录当前选中窗口的应用（用于检测应用切换）
    private var currentSelectedAppBundleID: String?

    // 是否启用应用分组切换功能（通过配置控制）
    private var isAppGroupSwitchEnabled: Bool {
        // 从配置中读取排序方式，如果是 appGroup 则启用
        return config.config.behavior.sortOrder == .appGroup
    }

    func selectNext() {
        Logger.info("==> selectNext called, selectedIndex: \(selectedIndex), count: \(filteredWindows.count)")
        guard !filteredWindows.isEmpty else {
            Logger.warning("==> selectNext: filteredWindows is empty!")
            return
        }

        let nextIndex = (selectedIndex + 1) % filteredWindows.count
        let nextWindow = filteredWindows[nextIndex]
        let currentWindow = filteredWindows[selectedIndex]

        Logger.info("==> selectNext: \(currentWindow.appName) -> \(nextWindow.appName)")

        // 检测是否切换到不同应用（使用 appName 判断，更稳定）
        let isAppSwitch = currentWindow.appName != nextWindow.appName

        // 只有启用应用分组功能且发生应用切换时才重新排列
        if isAppGroupSwitchEnabled && isAppSwitch {
            // 应用切换：重新排列窗口顺序
            filteredWindows = rearrangeWindowsForAppSwitch(
                from: currentWindow,
                to: nextWindow,
                in: filteredWindows
            )
            selectedIndex = 0  // 切换后选中新应用的第一窗口
            Logger.info("==> selectNext: app switch, new index: 0")
        } else {
            // 同一应用内切换或不启用功能时
            selectedIndex = nextIndex
            Logger.info("==> selectNext: same app switch, new index: \(nextIndex)")
        }

        loadPreview(for: filteredWindows[selectedIndex])
    }

    func selectPrevious() {
        guard !filteredWindows.isEmpty else { return }

        let prevIndex = (selectedIndex - 1 + filteredWindows.count) % filteredWindows.count
        let prevWindow = filteredWindows[prevIndex]
        let currentWindow = filteredWindows[selectedIndex]

        // 检测是否切换到不同应用（使用 appName 判断，更稳定）
        let isAppSwitch = currentWindow.appName != prevWindow.appName

        // 只有启用应用分组功能且发生应用切换时才重新排列
        if isAppGroupSwitchEnabled && isAppSwitch {
            // 应用切换：重新排列窗口顺序
            filteredWindows = rearrangeWindowsForAppSwitch(
                from: currentWindow,
                to: prevWindow,
                in: filteredWindows
            )
            selectedIndex = 0  // 切换后选中新应用的第一窗口
        } else {
            // 同一应用内切换或不启用功能时
            selectedIndex = prevIndex
        }

        loadPreview(for: filteredWindows[selectedIndex])
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
            // 已在第一行，不做处理或循环到最后一行
            return
        }

        // 计算上一行同列位置
        let targetIndex = (currentRow - 1) * columnCount + currentCol

        // 边界检查：确保目标索引有效
        if targetIndex < filteredWindows.count {
            selectedIndex = targetIndex
            loadPreview(for: filteredWindows[selectedIndex])
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
            selectedIndex = targetIndex
            loadPreview(for: filteredWindows[selectedIndex])
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

    /// 根据应用切换重新排列窗口顺序
    /// 排列规则：
    /// 1. 目标应用的窗口在最前（按活跃度降序）
    /// 2. 原应用的其他窗口次之（按活跃度降序）
    /// 3. 其他应用窗口最后（按活跃度降序）
    private func rearrangeWindowsForAppSwitch(
        from currentWindow: WindowModel,
        to targetWindow: WindowModel,
        in windows: [WindowModel]
    ) -> [WindowModel] {
        let targetAppBundleID = targetWindow.bundleIdentifier
        let currentAppBundleID = currentWindow.bundleIdentifier

        // 按应用分组
        var targetAppWindows: [WindowModel] = []
        var currentAppWindows: [WindowModel] = []
        var otherAppWindows: [WindowModel] = []

        for window in windows {
            if window.bundleIdentifier == targetAppBundleID {
                // 跳过目标窗口本身，避免重复
                if window.id != targetWindow.id {
                    targetAppWindows.append(window)
                }
            } else if window.bundleIdentifier == currentAppBundleID {
                currentAppWindows.append(window)
            } else {
                otherAppWindows.append(window)
            }
        }

        // 按活跃度排序（最近活跃的在前）
        targetAppWindows.sort { $0.lastActiveTime > $1.lastActiveTime }
        currentAppWindows.sort { $0.lastActiveTime > $1.lastActiveTime }
        otherAppWindows.sort { $0.lastActiveTime > $1.lastActiveTime }

        // 组合：新窗口 + 原应用窗口 + 其他应用窗口
        var result: [WindowModel] = []
        result.append(targetWindow)                    // 目标窗口在最前
        result.append(contentsOf: targetAppWindows)   // 目标应用其他窗口
        result.append(contentsOf: currentAppWindows)  // 原应用其他窗口
        result.append(contentsOf: otherAppWindows)    // 其他应用窗口

        Logger.debug("App switch: \(currentWindow.appName) -> \(targetWindow.appName), rearranged to \(result.count) windows")

        return result
    }

    func activateSelected() {
        guard filteredWindows.indices.contains(selectedIndex) else {
            Logger.warning("activateSelected: selectedIndex \(selectedIndex) out of bounds, filtered count: \(filteredWindows.count)")
            return
        }
        let window = filteredWindows[selectedIndex]
        Logger.info("activateSelected: activating \(window.appName) (PID: \(window.ownerPID), Title: \(window.windowTitle))")
        // 激活前先刷新窗口缓存
        windowManager.refreshCache()
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
            let fresh = windowManager.getAllWindows()
            windows = fresh
            applyFilter()
        }
    }

    var selectedWindow: WindowModel? {
        filteredWindows.indices.contains(selectedIndex) ? filteredWindows[selectedIndex] : nil
    }

    private func loadVisiblePreviews() {
        // 使用多线程并行加载所有可见窗口的预览
        let windowsToLoad = Array(filteredWindows.prefix(20))  // 增加到20个窗口
        
        Task {
            await withTaskGroup(of: Void.self) { group in
                for window in windowsToLoad {
                    // 跳过已有缓存的窗口
                    if previewImages[window.id] != nil { continue }
                    
                    group.addTask { [weak self] in
                        await self?.loadPreviewAsync(for: window)
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

            // 低优先级预加载（不阻塞主线程）
            Task.detached(priority: .background) { [weak self] in
                guard let self = self else { return }
                
                let size = CGSize(width: 124, height: 70)  // 小尺寸预览
                // PreviewGenerator 内部已包含缓存逻辑
                if let img = await self.previewGenerator.generatePreview(for: windowToPreload, size: size) {
                    await MainActor.run {
                        self.previewImages[windowToPreload.id] = img
                    }
                }
            }
        }
    }
}
