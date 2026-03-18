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

    init(windows: [WindowModel],
         windowManager: WindowManagerProtocol,
         previewGenerator: PreviewGenerator,
         filterEngine: FilterEngine) {
        self.windowManager = windowManager
        self.previewGenerator = previewGenerator
        self.filterEngine = filterEngine
        self.windows = windows
        applyFilter()
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
        windowManager.closeWindow(window)
        windows.removeAll { $0.id == window.id }
        applyFilter()
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
            let size = CGSize(
                width: config.config.appearance.previewWidth,
                height: config.config.appearance.previewHeight
            )
            if let image = await previewGenerator.generatePreview(for: window, size: size) {
                previewImages[window.id] = image
            }
        }
    }
}
