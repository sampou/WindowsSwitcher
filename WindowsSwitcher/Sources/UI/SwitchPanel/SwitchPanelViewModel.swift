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
        let criteria = FilterCriteria(
            searchText: searchText,
            showMinimized: config.config.behavior.showMinimizedWindows,
            showHidden: config.config.behavior.showHiddenWindows
        )
        filteredWindows = filterEngine.filter(windows, by: criteria)
        filteredWindows = filterEngine.sort(filteredWindows, by: config.config.behavior.sortOrder)
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
        for window in filteredWindows.prefix(10) {
            loadPreview(for: window)
        }
    }

    private func loadPreview(for window: WindowModel) {
        Task {
            let size = CGSize(width: 124, height: 70)
            // BUG-020: 3 秒超时，防止 PreviewGenerator 卡住导致 UI 无响应
            let image = await withTaskGroup(of: NSImage?.self) { group in
                group.addTask {
                    await self.previewGenerator.generatePreview(for: window, size: size)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
            if let image {
                previewImages[window.id] = image
            }
        }
    }
}
