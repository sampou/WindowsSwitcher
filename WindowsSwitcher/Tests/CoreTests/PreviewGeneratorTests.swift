import XCTest
@testable import WindowsSwitcher

// MARK: - T-032 预览生成器测试
final class PreviewGeneratorTests: XCTestCase {

    // MARK: - PreviewCache Actor 测试

    func testCacheStoreAndRetrieve() async {
        let cache = PreviewCache(persistsToDisk: false)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let windowID: CGWindowID = 42
        await cache.set(image, for: windowID)
        let retrieved = await cache.get(for: windowID)

        XCTAssertNotNil(retrieved, "缓存应能取回已存储的图片")
    }

    func testCacheMissReturnsNil() async {
        let cache = PreviewCache(persistsToDisk: false)
        let result = await cache.get(for: 9999)
        XCTAssertNil(result, "未存储的 windowID 应返回 nil")
    }

    func testCacheClear() async {
        let cache = PreviewCache(persistsToDisk: false)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        await cache.set(image, for: 1)
        await cache.set(image, for: 2)

        await cache.clear()

        let r1 = await cache.get(for: 1)
        let r2 = await cache.get(for: 2)
        XCTAssertNil(r1, "清除后应返回 nil")
        XCTAssertNil(r2, "清除后应返回 nil")
    }

    func testCacheEvictsWhenFull() async {
        let cache = PreviewCache(persistsToDisk: false)
        let image = NSImage(size: NSSize(width: 10, height: 10))

        // 写入超过 maxSize(80) 个条目
        for i in 0..<85 {
            await cache.set(image, for: CGWindowID(i))
        }
        // 不崩溃即通过，缓存自动淘汰最旧条目
        let recent = await cache.get(for: 84)
        XCTAssertNotNil(recent, "最新写入的条目应仍在缓存中")
    }

    // MARK: - PreviewGenerator 测试

    func testClearCacheDoesNotCrash() async {
        let generator = PreviewGenerator()
        await generator.clearCache()
        // 不崩溃即通过
    }

    func testGeneratePreviewForInvalidWindow() async {
        let generator = PreviewGenerator()
        let invalidWindow = makeInvalidWindow()
        let result = await generator.generatePreview(
            for: invalidWindow,
            size: CGSize(width: 320, height: 240)
        )
        // 无效窗口 ID 应返回 nil，不崩溃
        XCTAssertNil(result, "无效窗口应返回 nil 预览")
    }

    func testConcurrentInvalidRealtimePreviewsDoNotExhaustWorkerThreads() async {
        let generators = (0..<20).map { _ in PreviewGenerator() }
        let requestCount = 100
        let windows = (0..<requestCount).map {
            makeInvalidWindow(id: CGWindowID(900_000 + $0))
        }

        let nilResultCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<requestCount {
                group.addTask {
                    let generator = generators[index % generators.count]
                    let image = await generator.generateRealtimePreview(
                        for: windows[index],
                        size: CGSize(width: 320, height: 240)
                    )
                    return image == nil
                }
            }

            var count = 0
            for await isNil in group where isNil {
                count += 1
            }
            return count
        }

        XCTAssertEqual(nilResultCount, requestCount, "无效窗口并发预览应全部快速返回 nil")
    }

    func testGeneratePreviewSize() async {
        let generator = PreviewGenerator()
        // 使用真实存在的窗口（取第一个屏幕上的窗口）
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let first = windowInfo.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let windowID = first[kCGWindowNumber as String] as? CGWindowID,
              let ownerPID = first[kCGWindowOwnerPID as String] as? pid_t
        else {
            // 无可用窗口时跳过
            return
        }

        let window = WindowModel(
            id: windowID,
            appName: first[kCGWindowOwnerName as String] as? String ?? "Unknown",
            bundleIdentifier: "",
            windowTitle: first[kCGWindowName as String] as? String ?? "",
            appIcon: NSImage(),
            frame: .zero,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: ownerPID
        )

        let targetSize = CGSize(width: 320, height: 240)
        let preview = await generator.generatePreview(for: window, size: targetSize)

        if let preview {
            XCTAssertGreaterThan(preview.size.width, 0, "预览图宽度应大于0")
            XCTAssertGreaterThan(preview.size.height, 0, "预览图高度应大于0")
        }
        // 若无屏幕录制权限则 preview 为 nil，不强制断言
    }

    // MARK: - ConfigManager 测试

    func testConfigDefaultValues() {
        let config = ConfigModel()
        XCTAssertEqual(config.appearance.theme, .auto)
        XCTAssertEqual(config.behavior.sortOrder, .recent)
        XCTAssertFalse(config.behavior.showOffScreenWindows)
        XCTAssertEqual(config.appearance.panelOpacity, 0.95, accuracy: 0.001)
    }

    func testConfigEncodeDecodeRoundtrip() throws {
        let original = ConfigModel()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)
        XCTAssertEqual(original, decoded, "编解码后配置应相同")
    }

    // MARK: - Helpers

    private func makeInvalidWindow(id: CGWindowID = 999_999) -> WindowModel {
        WindowModel(
            id: id,
            appName: "InvalidApp",
            bundleIdentifier: "com.invalid.app",
            windowTitle: "Invalid Window",
            appIcon: NSImage(),
            frame: .zero,
            isMinimized: false,
            isHidden: false,
            isOnScreen: false,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: 0
        )
    }
}
