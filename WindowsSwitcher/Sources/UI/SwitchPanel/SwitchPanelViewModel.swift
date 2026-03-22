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
        windows = fresh
        applyFilter()
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

    func selectNext() {
        guard !filteredWindows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % filteredWindows.count
        loadPreview(for: filteredWindows[selectedIndex])
    }

    func selectPrevious() {
        guard !filteredWindows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + filteredWindows.count) % filteredWindows.count
        loadPreview(for: filteredWindows[selectedIndex])
    }

    func activateSelected() {
        guard filteredWindows.indices.contains(selectedIndex) else { return }
        windowManager.activateWindow(filteredWindows[selectedIndex])
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
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            let fresh = windowManager.getAllWindows()
            windows = fresh
            applyFilter()
        }
    }

    var selectedWindow: WindowModel? {
        filteredWindows.indices.contains(selectedIndex) ? filteredWindows[selectedIndex] : nil
    }

    private func loadVisiblePreviews() {
        // T-063: 跳过已缓存的预览，避免重复生成
        for window in filteredWindows.prefix(10) {
            guard previewImages[window.id] == nil else { continue }
            loadPreview(for: window)
        }
    }

    private func loadPreview(for window: WindowModel) {
        // BUG-020: Box 包装解决 macOS 13 NSImage Sendable 警告
        struct ImageBox: @unchecked Sendable { let image: NSImage }
        Task {
            let size = CGSize(width: 124, height: 70)
            let box: ImageBox? = await withTaskGroup(of: ImageBox?.self) { group in
                group.addTask { [previewGenerator] in
                    guard let img = await previewGenerator.generatePreview(for: window, size: size)
                    else { return nil }
                    return ImageBox(image: img)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return nil
                }
                for await result in group {
                    if let result { group.cancelAll(); return result }
                }
                return nil
            }
            if let image = box?.image {
                previewImages[window.id] = image
            }
        }
    }
}
