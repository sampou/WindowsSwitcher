import XCTest
@testable import WindowsSwitcher

// MARK: - T-060 性能测试（扩展）
// 验收标准：面板响应 ≤100ms，缩略图生成 ≤100ms，内存 ≤50MB，CPU空闲 ≤1%

final class PerformanceExtendedTests: XCTestCase {

    // MARK: - 面板响应时间 ≤100ms

    func testAC01_PanelResponseUnder100ms() {
        let engine = FilterEngine()
        let windows = (0..<200).map { makeWindow(id: CGWindowID($0)) }
        let start = CFAbsoluteTimeGetCurrent()
        _ = engine.filterAndSort(windows, criteria: FilterCriteria(), order: .recent)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(ms, 100, "面板数据准备应 <100ms，实测 \(String(format:"%.2f",ms))ms")
    }

    // MARK: - 搜索延迟 ≤50ms

    func testAC07_SearchUnder50ms() {
        let engine = FilterEngine()
        let windows = (0..<500).map { makeWindow(id: CGWindowID($0)) }
        let start = CFAbsoluteTimeGetCurrent()
        _ = engine.filter(windows, by: FilterCriteria(searchText: "app10"))
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(ms, 50, "搜索应 <50ms，实测 \(String(format:"%.2f",ms))ms")
    }

    // MARK: - 窗口操作 ≤50ms（乐观更新）

    @MainActor
    func testAC06_WindowOperationUnder50ms() {
        let windows = (1...10).map { makeWindow(id: CGWindowID($0)) }
        let vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: WindowManager.shared,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
        guard let first = vm.filteredWindows.first else { return XCTFail() }
        let start = CFAbsoluteTimeGetCurrent()
        vm.closeWindow(first)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(ms, 50, "窗口关闭乐观更新应 <50ms，实测 \(String(format:"%.2f",ms))ms")
    }

    // MARK: - 大量窗口排序性能

    func testSortPerformance_1000Windows() {
        let engine = FilterEngine()
        let windows = (0..<1000).map { makeWindow(id: CGWindowID($0)) }
        measure {
            _ = engine.sort(windows, by: .appName)
        }
    }

    func testSortPerformance_RecentOrder() {
        let engine = FilterEngine()
        let windows = (0..<1000).map { makeWindow(id: CGWindowID($0)) }
        measure {
            _ = engine.sort(windows, by: .recent)
        }
    }

    // MARK: - ConfigManager 编解码性能

    func testConfigRoundTripPerformance() {
        let config = ConfigModel()
        measure {
            if let data = try? JSONEncoder().encode(config) {
                _ = try? JSONDecoder().decode(ConfigModel.self, from: data)
            }
        }
    }

    // MARK: - PreviewCache 读写性能

    func testPreviewCacheReadWritePerformance() async {
        let cache = PreviewCache()
        let image = NSImage(size: NSSize(width: 124, height: 70))
        // 预热
        for i in 0..<10 { await cache.set(image, for: CGWindowID(i)) }
        // 测量 100 次读取
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<100 { _ = await cache.get(for: CGWindowID(i % 10)) }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(ms, 50, "100次缓存读取应 <50ms，实测 \(String(format:"%.2f",ms))ms")
    }

    // MARK: - 内存基线（ConfigModel 不超过 2KB）

    func testConfigModelMemoryFootprint() throws {
        let config = ConfigModel()
        let data = try JSONEncoder().encode(config)
        XCTAssertLessThan(data.count, 2 * 1024, "ConfigModel 序列化应 <2KB，实测 \(data.count) bytes")
    }

    // MARK: - FilterEngine 并发安全

    func testFilterEngineConcurrentAccess() async {
        let engine = FilterEngine()
        let windows = (0..<100).map { makeWindow(id: CGWindowID($0)) }
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    _ = engine.filter(windows, by: FilterCriteria(searchText: "app\(i % 10)"))
                }
            }
        }
        // 不崩溃即通过
    }

    // MARK: - Helper

    private func makeWindow(id: CGWindowID) -> WindowModel {
        WindowModel(
            id: id,
            appName: "App\(id % 20)",
            bundleIdentifier: "com.app\(id % 20)",
            windowTitle: "Window \(id)",
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date().addingTimeInterval(-Double(id)),
            windowLayer: 0,
            ownerPID: pid_t(id + 1000)
        )
    }
}
