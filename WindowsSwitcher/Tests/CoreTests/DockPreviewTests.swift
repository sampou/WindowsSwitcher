import XCTest
import Combine
@testable import WindowsSwitcher

// MARK: - F12 程序坞预览功能测试

@MainActor
final class DockPreviewTests: XCTestCase {

    var manager: DockPreviewManager!
    var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        manager = DockPreviewManager.shared
        cancellables = []
        ConfigManager.shared.reset()
        // 清理单例状态
        manager.previewItems = []
        manager.isPreviewVisible = false
        manager.hoveredIndex = nil
    }

    override func tearDown() async throws {
        manager.stop()
        cancellables = nil
        ConfigManager.shared.reset()
    }

    // MARK: - F12-T08 单例模式测试

    func testSingletonPattern() {
        let instance1 = DockPreviewManager.shared
        let instance2 = DockPreviewManager.shared
        XCTAssertTrue(instance1 === instance2, "DockPreviewManager 应该是单例")
    }

    // MARK: - F12-T09 start/stop 测试

    func testStartStopMonitoring() {
        XCTAssertNoThrow(manager.start(), "start() 不应抛出异常")
        XCTAssertNoThrow(manager.stop(), "stop() 不应抛出异常")
    }

    // MARK: - F12-T11 无窗口处理测试

    func testHandleEmptyWindows() {
        manager.start()

        // 初始状态应该是空的
        XCTAssertTrue(manager.previewItems.isEmpty, "初始状态 previewItems 应该为空")
    }

    // MARK: - DockPreviewConfig 配置测试

    func testDockPreviewConfigDefaults() {
        let config = DockPreviewConfig()

        XCTAssertTrue(config.enabled, "默认应该启用")
        XCTAssertEqual(config.hoverDelay, 0.05, "悬停延迟默认 50ms")
        XCTAssertEqual(config.hideDelay, 0.1, "隐藏延迟默认 100ms")
        XCTAssertEqual(config.maxPreviewCount, 4, "最大预览数默认 4")
        XCTAssertEqual(config.previewWidth, 104, "预览宽度默认 104pt")
        XCTAssertEqual(config.previewHeight, 58, "预览高度默认 58pt")
        XCTAssertTrue(config.showAnimation, "默认显示动画")
    }

    func testDockPreviewConfigCustomValues() {
        let config = DockPreviewConfig(
            enabled: false,
            hoverDelay: 0.5,
            hideDelay: 0.3,
            maxPreviewCount: 6,
            previewWidth: 120,
            previewHeight: 68,
            showAnimation: false
        )

        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.hoverDelay, 0.5)
        XCTAssertEqual(config.hideDelay, 0.3)
        XCTAssertEqual(config.maxPreviewCount, 6)
        XCTAssertEqual(config.previewWidth, 120)
        XCTAssertEqual(config.previewHeight, 68)
        XCTAssertFalse(config.showAnimation)
    }

    // MARK: - DockPreviewItem 测试

    func testDockPreviewItemCreation() {
        let window = makeMockWindow(id: 1, app: "Safari", title: "Apple")
        let item = DockPreviewItem(windowModel: window)

        XCTAssertEqual(item.windowTitle, "Apple")
        XCTAssertNotNil(item.appIcon)
        XCTAssertNotNil(item.id)
    }

    func testDockPreviewItemUsesAppNameWhenTitleEmpty() {
        let window = makeMockWindow(id: 1, app: "Safari", title: "")
        let item = DockPreviewItem(windowModel: window)

        XCTAssertEqual(item.windowTitle, "Safari", "标题为空时应使用应用名")
    }

    // MARK: - DockPosition 测试

    func testDockPositionCases() {
        let positions: [DockPosition] = [.top, .bottom, .left, .right]
        XCTAssertEqual(positions.count, 4, "应该有 4 种 Dock 位置")
    }

    // MARK: - F12-T18 最大窗口数测试

    func testMaxPreviewCount() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertEqual(config.maxPreviewCount, 4, "最大预览数应该是 4")
    }

    // MARK: - F12-T24 悬停触发延迟测试

    func testHoverDelayConfiguration() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertGreaterThanOrEqual(config.hoverDelay, 0.05, "悬停延迟应该 >= 50ms")
        XCTAssertLessThanOrEqual(config.hoverDelay, 1.0, "悬停延迟应该 <= 1000ms")
    }

    // MARK: - F12-T25 隐藏延迟测试

    func testHideDelayConfiguration() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertGreaterThanOrEqual(config.hideDelay, 0.1, "隐藏延迟应该 >= 100ms")
        XCTAssertLessThanOrEqual(config.hideDelay, 1.0, "隐藏延迟应该 <= 1000ms")
    }

    // MARK: - F12-T26 动画显示配置测试

    func testShowAnimationConfiguration() {
        // 默认应该启用动画
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertTrue(config.showAnimation, "默认应该启用动画")

        // 测试可以修改为禁用
        ConfigManager.shared.updateDockPreview { $0.showAnimation = false }
        XCTAssertFalse(ConfigManager.shared.config.dockPreview.showAnimation)

        // 恢复默认
        ConfigManager.shared.updateDockPreview { $0.showAnimation = true }
        XCTAssertTrue(ConfigManager.shared.config.dockPreview.showAnimation)
    }

    // MARK: - F12-T27 预览图尺寸测试

    func testPreviewDimensionsConfiguration() {
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertEqual(config.previewWidth, 104, "预览图宽度应该是 104")
        XCTAssertEqual(config.previewHeight, 58, "预览图高度应该是 58")
    }

    // MARK: - F12-T28 启用状态配置测试

    func testDockPreviewEnabledConfiguration() {
        // 默认应该启用
        let config = ConfigManager.shared.config.dockPreview
        XCTAssertTrue(config.enabled, "默认应该启用程序坞预览")

        // 测试可以修改为禁用
        ConfigManager.shared.updateDockPreview { $0.enabled = false }
        XCTAssertFalse(ConfigManager.shared.config.dockPreview.enabled)

        // 恢复默认
        ConfigManager.shared.updateDockPreview { $0.enabled = true }
        XCTAssertTrue(ConfigManager.shared.config.dockPreview.enabled)
    }

    // MARK: - F12-T29 最大预览数选项测试 (2/4/6/8)

    func testMaxPreviewCountOptions() {
        // 测试所有有效选项
        let validOptions = [2, 4, 6, 8]

        for option in validOptions {
            ConfigManager.shared.updateDockPreview { $0.maxPreviewCount = option }
            XCTAssertEqual(ConfigManager.shared.config.dockPreview.maxPreviewCount, option,
                "应该能设置为 \(option) 个")
        }

        // 恢复默认值
        ConfigManager.shared.updateDockPreview { $0.maxPreviewCount = 4 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.maxPreviewCount, 4)
    }

    // MARK: - F12-T30 悬停延迟范围测试 (50ms-1000ms)

    func testHoverDelayRange() {
        // 测试最小值
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.05 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 0.05, "应该能设置为 50ms")

        // 测试最大值
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 1.0 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 1.0, "应该能设置为 1000ms")

        // 测试中间值
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.35 }
        XCTAssertEqual(ConfigManager.shared.config.dockPreview.hoverDelay, 0.35, "应该能设置为 350ms")

        // 恢复默认值
        ConfigManager.shared.updateDockPreview { $0.hoverDelay = 0.05 }
    }

    // MARK: - 通知测试

    func testDockPreviewWindowSelectedNotification() {
        let expectation = expectation(description: "dockPreviewWindowSelected notification")

        let observer = NotificationCenter.default.addObserver(
            forName: .dockPreviewWindowSelected,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        // 发送测试通知
        NotificationCenter.default.post(name: .dockPreviewWindowSelected, object: nil)

        waitForExpectations(timeout: 1.0)

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - 预览图尺寸比例测试 (16:9)

    func testPreviewAspectRatioIs16by9() {
        let config = ConfigManager.shared.config.dockPreview
        let ratio = config.previewWidth / config.previewHeight

        // 16:9 = 1.778
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.1, "预览图比例应该接近 16:9")
    }

    // MARK: - 辅助方法

    private func makeMockWindow(id: CGWindowID, app: String, title: String) -> WindowModel {
        WindowModel(
            id: id,
            appName: app,
            bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: title,
            appIcon: NSImage(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: pid_t(id * 100)
        )
    }
}

// MARK: - DockEventMonitor 单元测试

final class DockEventMonitorTests: XCTestCase {

    func testDockPositionEnumExists() {
        let top = DockPosition.top
        let bottom = DockPosition.bottom
        let left = DockPosition.left
        let right = DockPosition.right

        // 验证枚举值可以创建
        XCTAssertNotNil(top)
        XCTAssertNotNil(bottom)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
    }

    func testDockPositionAllCases() {
        let allPositions: [DockPosition] = [.top, .bottom, .left, .right]
        XCTAssertEqual(allPositions.count, 4)
    }

    /// R3 关闭项：重复 start/stop 不会让 `localMouseMonitor` 累积。
    /// 通过反射读出当前全局/本地监听器数量；CI 无 macOS 真实 AppKit 时该属性为 nil，仍能验证 `stopMonitoring` 不再泄漏本地监听器引用。
    func testRepeatedStartStopCleansAllMonitors() {
        let monitor = DockEventMonitor()
        monitor.startMonitoring()
        monitor.startMonitoring()  // 重复 start 不应叠加 global monitor
        monitor.stopMonitoring()
        monitor.stopMonitoring()  // 第二次 stop 幂等
        // 反射读取私有计数；至少不能崩溃
        let globalCount = monitor.activeMonitorCount
        XCTAssertEqual(globalCount, 0, "stop 后全局监听器应被全部移除")
        let localCount = monitor.activeLocalMonitorCount
        XCTAssertEqual(localCount, 0, "stop 后本地监听器应被全部移除，防止重复 start/stop 累积回调")
    }

    /// R3 关闭项：`stopMonitoring` 后悬停相关状态被重置，避免旧 callback 干扰下一次悬停。
    /// Dock 客观可见性（`isDockVisible`）由系统决定；本测试只验证我们主动维护的悬停状态。
    func testStopMonitoringResetsHoverState() {
        let monitor = DockEventMonitor()
        monitor.startMonitoring()
        // 模拟悬停：手动设置悬停状态（不依赖真实鼠标事件）
        monitor.simulateHoverForTesting(bundleID: "com.apple.Safari", iconCenter: .zero)
        XCTAssertNotNil(monitor.hoveredAppBundleIDForTesting, "悬停后应能读取到 bundle ID")
        monitor.stopMonitoring()
        XCTAssertNil(monitor.hoveredAppBundleIDForTesting, "stop 后必须清空 hoveredAppBundleID")
        XCTAssertNil(monitor.hoveredIconInfoForTesting, "stop 后必须清空 hoveredIconInfo")
    }
}

// MARK: - DesignTokens DockPreview 规格测试

final class DockPreviewDesignTokensTests: XCTestCase {

    func testDockPreviewDesignTokens() {
        XCTAssertEqual(DesignTokens.DockPreview.panelCornerRadius, 10)
        XCTAssertEqual(DesignTokens.DockPreview.shadowRadius, 12)
        XCTAssertEqual(DesignTokens.DockPreview.shadowY, 4)
        XCTAssertEqual(DesignTokens.DockPreview.itemWidth, 120)
        XCTAssertEqual(DesignTokens.DockPreview.itemHeight, 80)
        XCTAssertEqual(DesignTokens.DockPreview.itemCornerRadius, 10)
        XCTAssertEqual(DesignTokens.DockPreview.previewWidth, 104)
        XCTAssertEqual(DesignTokens.DockPreview.previewHeight, 58)
        XCTAssertEqual(DesignTokens.DockPreview.previewCornerRadius, 8)
        XCTAssertEqual(DesignTokens.DockPreview.titleFontSize, 11)
        XCTAssertEqual(DesignTokens.DockPreview.itemSpacing, 8)
        XCTAssertEqual(DesignTokens.DockPreview.showDelay, 0.35)
        XCTAssertEqual(DesignTokens.DockPreview.showDuration, 0.2)
        XCTAssertEqual(DesignTokens.DockPreview.hideDuration, 0.15)
    }

    func testDockPreviewAspectRatio() {
        let ratio = DesignTokens.DockPreview.previewWidth / DesignTokens.DockPreview.previewHeight
        // 104:58 ≈ 16:9 (1.79)
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.1, "Dock预览图比例应该接近 16:9")
    }

    // MARK: - 新功能测试：预览窗口显示/隐藏逻辑

    func testDockPreviewManagerSingleton() {
        // 验证单例存在
        let manager = DockPreviewManager.shared
        XCTAssertNotNil(manager, "DockPreviewManager 单例应该存在")
    }

    func testIsPreviewVisibleDefaultValue() {
        // 验证默认状态为隐藏
        let manager = DockPreviewManager.shared
        XCTAssertFalse(manager.isPreviewVisible, "预览窗口默认应该隐藏")
    }

    func testIsPreviewVisibleStateChange() {
        let manager = DockPreviewManager.shared

        // 初始状态为隐藏
        XCTAssertFalse(manager.isPreviewVisible)

        // 手动设置显示状态
        manager.isPreviewVisible = true
        XCTAssertTrue(manager.isPreviewVisible, "预览窗口应该显示")

        // 手动设置隐藏状态
        manager.isPreviewVisible = false
        XCTAssertFalse(manager.isPreviewVisible, "预览窗口应该隐藏")
    }

    func testHidePreviewPanelMethod() {
        let manager = DockPreviewManager.shared

        // 先显示预览
        manager.isPreviewVisible = true
        XCTAssertTrue(manager.isPreviewVisible)

        // 调用 hidePreviewPanel 隐藏预览
        manager.hidePreviewPanel()
        XCTAssertFalse(manager.isPreviewVisible, "hidePreviewPanel 应该隐藏预览")
    }

    func testPreviewItemsDefaultEmpty() {
        let manager = DockPreviewManager.shared
        XCTAssertTrue(manager.previewItems.isEmpty, "预览项默认应该为空")
    }

    func testHoveredIndexDefaultNil() {
        let manager = DockPreviewManager.shared
        XCTAssertNil(manager.hoveredIndex, "悬停索引默认应该为 nil")
    }

    func testDockPositionDefaultBottom() {
        let manager = DockPreviewManager.shared
        XCTAssertEqual(manager.currentDockPosition, .bottom, "Dock 位置默认应该是底部")
    }

    func testDockPreviewManagerHasPreviewGenerator() {
        let manager = DockPreviewManager.shared
        XCTAssertNotNil(manager.previewGenerator, "应该包含共享的 PreviewGenerator")
    }

    func testDockPreviewManagerUsesInjectedSharedPreviewGenerator() {
        let manager = DockPreviewManager.shared
        let sharedGenerator = PreviewGenerator()

        manager.configure(previewGenerator: sharedGenerator)

        XCTAssertTrue(
            manager.previewGenerator === sharedGenerator,
            "程序坞预览应使用 AppDelegate 注入的切换器预览缓存实例"
        )
    }

    // MARK: - 程序坞预览面板布局一致性测试

    /// 面板宽度必须包含每个窗口项的左右留白。
    ///
    /// 此前 AppDelegate 与 SwiftUI 视图各算一份尺寸：AppDelegate 用间距 20 且不含窗口项留白，
    /// 视图用间距 8 且含留白，两者不一致会让内容被裁切并与窗口错位。
    func testDockPreviewLayoutPanelWidthIncludesItemPadding() {
        let itemWidth: CGFloat = 130
        let itemHeight: CGFloat = 110
        let panelPadding: CGFloat = 16
        let itemsPerRow = 4

        for count in 1...itemsPerRow {
            let metrics = DockPreviewLayout.metrics(
                itemCount: count,
                itemWidth: itemWidth,
                itemHeight: itemHeight,
                panelPadding: panelPadding,
                itemsPerRow: itemsPerRow,
                availableScreenHeight: 1000
            )

            let expectedWidth = CGFloat(count) * (itemWidth + DockPreviewLayout.itemPadding * 2) + panelPadding * 2
            XCTAssertEqual(
                metrics.panelWidth,
                expectedWidth,
                accuracy: 0.001,
                "窗口数为 \(count) 时面板宽度应与 SwiftUI 内容宽度一致"
            )
        }
    }

    /// 窗口数量变化时面板高度必须随之变化：面板尺寸不更新会让内容被裁切。
    func testDockPreviewLayoutHeightGrowsWithItemCount() {
        let itemWidth: CGFloat = 130
        let itemHeight: CGFloat = 110
        let panelPadding: CGFloat = 16
        let itemsPerRow = 4

        func height(for count: Int) -> CGFloat {
            DockPreviewLayout.metrics(
                itemCount: count,
                itemWidth: itemWidth,
                itemHeight: itemHeight,
                panelPadding: panelPadding,
                itemsPerRow: itemsPerRow,
                availableScreenHeight: 1000
            ).totalHeight
        }

        XCTAssertGreaterThan(
            height(for: 8),
            height(for: 4),
            "两行窗口的面板应比一行更高"
        )
        XCTAssertLessThan(
            height(for: 0),
            height(for: 1),
            "没有窗口时不应保留窗口项占位高度"
        )
    }

    /// 超出可视高度时进入滚动模式，并额外保留滚动提示条高度。
    func testDockPreviewLayoutEnablesScrollingBeyondMaxHeight() {
        let metrics = DockPreviewLayout.metrics(
            itemCount: 60,
            itemWidth: 130,
            itemHeight: 110,
            panelPadding: 16,
            itemsPerRow: 4,
            availableScreenHeight: 600
        )

        XCTAssertTrue(metrics.needsScrolling, "窗口过多时应该进入滚动模式")
        XCTAssertEqual(metrics.rows, 15, "60 个窗口每行 4 个应该是 15 行")
        XCTAssertGreaterThan(
            metrics.totalHeight,
            metrics.contentHeight,
            "滚动模式下面板总高度应包含滚动提示条"
        )
    }

    // MARK: - 同标题窗口消歧测试

    /// 同标题的多个窗口必须按几何位置消歧，否则会激活到同应用的另一个窗口。
    func testSelectClosestCandidatePicksNearestFrameAmongSameTitleWindows() {
        let target = CGRect(x: 100, y: 200, width: 800, height: 600)
        let frames: [CGRect?] = [
            CGRect(x: 900, y: 900, width: 400, height: 300),
            CGRect(x: 104, y: 204, width: 800, height: 600),
            CGRect(x: 300, y: 200, width: 800, height: 600)
        ]

        let index = WindowManager.selectClosestCandidate(frames: frames, targetFrame: target)

        XCTAssertEqual(index, 1, "应选中几何最接近目标的那个窗口")
    }

    /// 候选都缺少 AX 位置时无法消歧，必须放弃而不是随便挑一个。
    func testSelectClosestCandidateReturnsNilWithoutUsableFrames() {
        let target = CGRect(x: 0, y: 0, width: 800, height: 600)

        let index = WindowManager.selectClosestCandidate(frames: [nil, nil], targetFrame: target)

        XCTAssertNil(index, "没有可用位置信息时不应猜测候选窗口")
    }

    // MARK: - 窗口身份判定测试（CGWindowID 复用防护）

    /// 构造测试用窗口模型
    private func makeWindow(
        id: CGWindowID,
        title: String,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        ownerPID: pid_t = 4242
    ) -> WindowModel {
        WindowModel(
            id: id,
            appName: "Safari",
            bundleIdentifier: "com.safari",
            windowTitle: title,
            appIcon: NSImage(),
            frame: frame,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: ownerPID,
            isStandardWindow: true
        )
    }

    /// 标题一致即认为是同一个窗口。
    func testIsSameWindowAcceptsIdenticalTitle() {
        let snapshot = makeWindow(id: 100, title: "文档 A")
        let live = makeWindow(id: 100, title: "文档 A")

        XCTAssertTrue(WindowManager.isSameWindow(live, snapshot))
    }

    /// 标题变了但位置尺寸未变，仍是同一个窗口（文档改名、网页标题更新）。
    func testIsSameWindowAcceptsSameGeometryWithChangedTitle() {
        let snapshot = makeWindow(id: 100, title: "文档 A")
        let live = makeWindow(id: 100, title: "文档 A 改名")

        XCTAssertTrue(
            WindowManager.isSameWindow(live, snapshot),
            "标题变化但几何未变时应视为同一个窗口"
        )
    }

    /// 标题与几何都变了，说明 CGWindowID 已被复用于另一个窗口，必须判为不同窗口。
    func testIsSameWindowRejectsRecycledWindowID() {
        let snapshot = makeWindow(id: 100, title: "文档 A")
        let recycled = makeWindow(
            id: 100,
            title: "完全不同的窗口",
            frame: CGRect(x: 2000, y: 2000, width: 400, height: 300)
        )

        XCTAssertFalse(
            WindowManager.isSameWindow(recycled, snapshot),
            "标题与几何都变化时应判定为窗口 ID 被复用"
        )
    }

    // MARK: - 程序坞预览排序规则测试

    /// 程序坞预览只按创建时间排序，不受最近使用时间影响。
    ///
    /// 此前被改成跟随切换面板的 MRU：点击某个窗口后它下次就排到最前，
    /// 同一个缩略图在两次悬停之间"跳位置"。
    func testDockPreviewSortsByCreationOrderNotByRecency() {
        let older = makeWindow(id: 100, title: "先创建的窗口")
        let newer = makeWindow(id: 200, title: "后创建的窗口")
        // 让"后创建"的窗口带上更新的最近使用时间
        let newerRecent = newer.withLastActiveTime(Date().addingTimeInterval(60))

        let sorted = DockPreviewManager.sortForDockPreview([newerRecent, older])

        XCTAssertEqual(
            sorted.map(\.id),
            [100, 200],
            "程序坞预览应按创建顺序排列，与最近使用时间无关"
        )
    }

    /// 输入顺序不影响结果，保证同一批窗口每次悬停顺序一致。
    func testDockPreviewSortIsStableRegardlessOfInputOrder() {
        let windows = [
            makeWindow(id: 300, title: "C"),
            makeWindow(id: 100, title: "A"),
            makeWindow(id: 200, title: "B")
        ]

        let first = DockPreviewManager.sortForDockPreview(windows).map(\.id)
        let second = DockPreviewManager.sortForDockPreview(windows.reversed()).map(\.id)

        XCTAssertEqual(first, [100, 200, 300])
        XCTAssertEqual(first, second, "排序结果不应受输入顺序影响")
    }

    // MARK: - 非标准窗口判定测试

    /// 应用名含 "dock" 的普通应用不应被当成系统程序坞。
    ///
    /// 此前用子串匹配，"Docker Desktop" 会被误判为非标准窗口：
    /// 最小化时由提供器列出（能看见），还原后走主枚举却被剔除（凭空消失）。
    func testAppNameExclusionDoesNotMatchSubstrings() {
        let rules = NonStandardWindowRules.self

        XCTAssertFalse(
            rules.isNonStandardWindow(
                bundleIdentifier: "com.electron.dockerdesktop",
                appName: "Docker Desktop",
                windowTitle: "Containers",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                windowLayer: 0
            ),
            "名称含 dock 的普通应用不应被判为系统程序坞"
        )
        XCTAssertFalse(
            rules.isNonStandardWindow(
                bundleIdentifier: "com.piratesoftware.blackparrot",
                appName: "Dockyard",
                windowTitle: "主控台",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                windowLayer: 0
            ),
            "名称含 dock 的普通应用不应被判为系统程序坞"
        )
    }

    /// 系统程序坞本身仍然要被排除。
    func testAppNameExclusionStillMatchesExactSystemApps() {
        XCTAssertTrue(
            NonStandardWindowRules.isNonStandardWindow(
                bundleIdentifier: "",
                appName: "Dock",
                windowTitle: "",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                windowLayer: 0
            ),
            "程序坞自身应被判为非标准窗口"
        )
        XCTAssertTrue(
            NonStandardWindowRules.isNonStandardWindow(
                bundleIdentifier: "",
                appName: "Notification Center",
                windowTitle: "",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                windowLayer: 0
            ),
            "通知中心应被判为非标准窗口"
        )
    }

    // MARK: - 最小化窗口提供器测试

    /// 查询结果被缓存，重复读取不会再次触发 AX 查询。
    func testMinimizedProviderCachesQueryResult() {
        var queryCount = 0
        let provider = MinimizedWindowProvider { pid, _, _ in
            queryCount += 1
            return [self.makeWindow(id: 900, title: "最小化的窗口", ownerPID: pid)]
        }

        let first = provider.windows(for: 111)
        let second = provider.windows(for: 111)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(queryCount, 1, "缓存有效期内不应重复查询")
    }

    /// AX 无响应（返回 nil）的进程被记入负缓存，短时间不再查询。
    func testMinimizedProviderSkipsUnresponsiveProcesses() {
        var queryCount = 0
        let provider = MinimizedWindowProvider { _, _, _ in
            queryCount += 1
            return nil
        }

        _ = provider.windows(for: 222)
        _ = provider.windows(for: 222)

        XCTAssertEqual(queryCount, 1, "无响应的进程应被负缓存跳过")
    }

    /// 已最小化的窗口标记正确，并进入缓存列表。
    func testMinimizedProviderExposesMinimizedWindows() {
        let provider = MinimizedWindowProvider { pid, _, _ in
            [self.makeWindow(id: 901, title: "最小化的窗口", ownerPID: pid)]
        }

        _ = provider.windows(for: 333)
        let cached = provider.cachedWindows(excluding: [])

        XCTAssertEqual(cached.count, 1)
        XCTAssertTrue(cached.first?.isMinimized == true)
    }

    /// 已经在屏幕上的窗口不应被最小化列表重复包含。
    func testMinimizedProviderExcludesKnownWindows() {
        let provider = MinimizedWindowProvider { pid, _, _ in
            [self.makeWindow(id: 902, title: "最小化的窗口", ownerPID: pid)]
        }

        _ = provider.windows(for: 444)
        let cached = provider.cachedWindows(excluding: [902])

        XCTAssertTrue(cached.isEmpty, "已在屏幕上的窗口不应重复出现")
    }

    // MARK: - 缩略图缓存身份校验测试
    /// 窗口 ID 被复用后，缓存里的旧截图不能显示在新窗口的卡片上。
    func testCachedPreviewRejectsMismatchedOwner() {
        let generator = PreviewGenerator()
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let original = makeWindow(id: 500, title: "文档 A")

        generator.seedSyncCacheForTesting(for: original, image: image)

        // 同一个 ID，但归属进程不同：属于 ID 复用后的新窗口
        let reused = makeWindow(id: 500, title: "文档 A", ownerPID: original.ownerPID + 1)

        XCTAssertNotNil(
            generator.getCachedPreviewSync(for: original),
            "归属一致时仍应命中缓存"
        )
        XCTAssertNil(
            generator.getCachedPreviewSync(for: reused),
            "归属不一致时不得复用旧窗口的缩略图"
        )
        XCTAssertNil(
            generator.getCachedPreviewSync(for: original),
            "身份不一致的条目应被清除，避免继续显示旧窗口的截图"
        )
    }
}
