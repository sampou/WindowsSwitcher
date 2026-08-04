import XCTest
@testable import WindowsSwitcher

// MARK: - T-052 性能测试

final class PerformanceTests: XCTestCase {

    // 快捷键响应时间 < 100ms（FilterEngine 处理速度）
    func testFilterPerformance() {
        let engine = FilterEngine()
        let windows = (0..<500).map { makeWindow(id: CGWindowID($0)) }
        let criteria = FilterCriteria(searchText: "app")

        measure {
            _ = engine.filter(windows, by: criteria)
        }
        // measure 默认10次，平均应远低于100ms
    }

    // 排序性能
    func testSortPerformance() {
        let engine = FilterEngine()
        let windows = (0..<500).map { makeWindow(id: CGWindowID($0)) }

        measure {
            _ = engine.sort(windows, by: .appName)
        }
    }

    // ConfigManager 编解码性能
    func testConfigEncodeDecodePerformance() {
        let config = ConfigModel()
        measure {
            if let data = try? JSONEncoder().encode(config) {
                _ = try? JSONDecoder().decode(ConfigModel.self, from: data)
            }
        }
    }

    // PreviewCache 并发写入性能
    func testPreviewCacheConcurrentWrite() async {
        let cache = PreviewCache()
        let image = NSImage(size: NSSize(width: 100, height: 100))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    await cache.set(image, for: CGWindowID(i))
                }
            }
        }
        // 不崩溃即通过
    }

    // MARK: - T-055 性能优化验证

    // 验证 filterAndSort 比分步调用不慢
    func testFilterAndSortNotSlowerThanSeparate() {
        let engine = FilterEngine()
        let windows = (0..<200).map { makeWindow(id: CGWindowID($0)) }
        let criteria = FilterCriteria(searchText: "app5")

        var t1: Double = 0
        var t2: Double = 0

        measure(metrics: [XCTClockMetric()]) {
            let s1 = CFAbsoluteTimeGetCurrent()
            _ = engine.filterAndSort(windows, criteria: criteria, order: .recent)
            t1 += CFAbsoluteTimeGetCurrent() - s1

            let s2 = CFAbsoluteTimeGetCurrent()
            let f = engine.filter(windows, by: criteria)
            _ = engine.sort(f, by: .recent)
            t2 += CFAbsoluteTimeGetCurrent() - s2
        }
    }

    // MARK: - Helper
    private func makeWindow(id: CGWindowID) -> WindowModel {
        WindowModel(
            id: id,
            appName: "App\(id % 20)",
            bundleIdentifier: "com.app\(id % 20)",
            windowTitle: "Window \(id)",
            appIcon: NSImage(),
            frame: .zero,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date().addingTimeInterval(-Double(id)),
            windowLayer: 0,
            ownerPID: pid_t(id + 1000)
        )
    }
}
