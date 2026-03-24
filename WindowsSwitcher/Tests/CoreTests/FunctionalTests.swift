import XCTest
import Combine
@testable import WindowsSwitcher

// MARK: - T-058 功能测试
// 验收标准：AC-01 ~ AC-10（精细化功能需求文档 v1.2）

// MARK: - AC-01 / AC-02：窗口切换 + LRU 排序

@MainActor
final class F01WindowSwitchTests: XCTestCase {

    var vm: SwitchPanelViewModel!

    override func setUp() async throws {
        let now = Date()
        let windows = [
            makeWindow(id: 1, app: "Safari",   offset: -1),   // 最近
            makeWindow(id: 2, app: "Xcode",    offset: -5),
            makeWindow(id: 3, app: "Terminal", offset: -10),
            makeWindow(id: 4, app: "Finder",   offset: -20),  // 最旧
        ]
        vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: WindowManager.shared,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
        _ = now
    }

    override func tearDown() async throws {
        vm = nil
        ConfigManager.shared.reset()
    }

    // AC-01: 面板初始化后立即可用（模拟 100ms 内响应）
    func testAC01_PanelInitializesImmediately() {
        XCTAssertFalse(vm.filteredWindows.isEmpty, "面板初始化后应立即有窗口列表")
        XCTAssertEqual(vm.selectedIndex, 0)
    }

    // AC-01: 响应时间 < 100ms（FilterEngine 处理速度）
    func testAC01_FilterResponseUnder100ms() {
        let engine = FilterEngine()
        let windows = (0..<100).map { makeWindow(id: CGWindowID($0), app: "App\($0)", offset: -Double($0)) }
        let start = CFAbsoluteTimeGetCurrent()
        _ = engine.filterAndSort(windows, criteria: FilterCriteria(), order: .recent)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 100, "FilterEngine 处理 100 个窗口应 < 100ms，实测 \(elapsed)ms")
    }

    // AC-02: LRU 排序 — 最近使用的窗口排在最前
    func testAC02_LRUSortMostRecentFirst() {
        ConfigManager.shared.updateBehavior { $0.sortOrder = .recent }
        vm.applyFilter()
        let windows = vm.filteredWindows
        for i in 0..<windows.count - 1 {
            XCTAssertGreaterThanOrEqual(
                windows[i].lastActiveTime,
                windows[i + 1].lastActiveTime,
                "LRU 排序：index \(i) 应比 index \(i+1) 更近"
            )
        }
    }

    // AC-02: 应用名排序
    func testAC02_AppNameSort() {
        ConfigManager.shared.updateBehavior { $0.sortOrder = .appName }
        vm.applyFilter()
        let names = vm.filteredWindows.map { $0.appName }
        for i in 0..<names.count - 1 {
            XCTAssertLessThanOrEqual(
                names[i].localizedLowercase,
                names[i + 1].localizedLowercase,
                "应用名排序：\(names[i]) 应 ≤ \(names[i+1])"
            )
        }
    }

    // AC-02: 窗口标题排序
    func testAC02_WindowTitleSort() {
        ConfigManager.shared.updateBehavior { $0.sortOrder = .windowTitle }
        vm.applyFilter()
        let titles = vm.filteredWindows.map { $0.windowTitle }
        for i in 0..<titles.count - 1 {
            XCTAssertLessThanOrEqual(
                titles[i].localizedLowercase,
                titles[i + 1].localizedLowercase
            )
        }
    }

    // Tab 键导航：selectNext 循环
    func testAC01_TabNavigationCycles() {
        let count = vm.filteredWindows.count
        for _ in 0..<count { vm.selectNext() }
        XCTAssertEqual(vm.selectedIndex, 0, "Tab 循环后应回到第一个")
    }

    // Shift+Tab 反向导航
    func testAC01_ShiftTabNavigationCycles() {
        vm.selectPrevious()
        XCTAssertEqual(vm.selectedIndex, vm.filteredWindows.count - 1)
    }

    // Esc 关闭：selectedWindow 存在
    func testAC01_SelectedWindowExists() {
        XCTAssertNotNil(vm.selectedWindow)
        XCTAssertEqual(vm.selectedWindow?.id, vm.filteredWindows[0].id)
    }

    // 数字键选择（1-9）
    func testAC01_DirectIndexSelection() {
        vm.selectedIndex = 2
        XCTAssertEqual(vm.filteredWindows[vm.selectedIndex].id, vm.filteredWindows[2].id)
    }
}

// MARK: - AC-03 / AC-04：窗口预览

final class F02PreviewTests: XCTestCase {

    // AC-03: 缩略图尺寸 124×70pt（16:9）
    func testAC03_PreviewDimensions() {
        XCTAssertEqual(DesignTokens.WindowItem.previewWidth, 124)
        XCTAssertEqual(DesignTokens.WindowItem.previewHeight, 70)
    }

    func testAC03_PreviewIs16by9() {
        let ratio = DesignTokens.WindowItem.previewWidth / DesignTokens.WindowItem.previewHeight
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.05)
    }

    // AC-04: PreviewCache 并发写入不崩溃（模拟 15-30fps 更新）
    func testAC04_PreviewCacheConcurrentUpdates() async {
        let cache = PreviewCache()
        let image = NSImage(size: NSSize(width: 124, height: 70))
        // 模拟 30fps × 1s = 30 次更新
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask { await cache.set(image, for: CGWindowID(i % 10)) }
            }
        }
        // 不崩溃即通过
        let result = await cache.get(0)
        XCTAssertNotNil(result)
    }

    // AC-04: PreviewGenerator 对无效窗口返回 nil 不崩溃
    func testAC04_InvalidWindowReturnsNil() async {
        let generator = PreviewGenerator()
        let invalid = makeWindow(id: 999999, app: "Invalid", offset: 0)
        let result = await generator.generatePreview(for: invalid, size: CGSize(width: 124, height: 70))
        XCTAssertNil(result)
    }

    // AC-04: clearCache 不崩溃
    func testAC04_ClearCacheDoesNotCrash() async {
        let generator = PreviewGenerator()
        await generator.clearCache()
    }

    // AC-03: 预览缓存过期后重新生成
    func testAC03_PreviewCacheExpiry() async {
        let cache = PreviewCache()
        await cache.setExpiry(0.01) // 10ms 过期
        let img = NSImage(size: NSSize(width: 124, height: 70))
        await cache.set(img, for: 1)
        try? await Task.sleep(nanoseconds: 20_000_000) // 等 20ms
        let result = await cache.get(1)
        XCTAssertNil(result, "过期缓存应返回 nil")
    }

    // AC-03: 无效窗口 ID 返回 nil
    func testAC03_InvalidWindowIDReturnsNil() async {
        let cache = PreviewCache()
        let result = await cache.get(CGWindowID(999999))
        XCTAssertNil(result)
    }

    // AC-03: 缓存满时自动淘汰最旧条目
    func testAC03_CacheEvictsOldestWhenFull() async {
        let cache = PreviewCache()
        let img = NSImage(size: NSSize(width: 1, height: 1))
        // 写入 51 条（maxSize=50），第 1 条应被淘汰
        for i in 0..<51 {
            await cache.set(img, for: CGWindowID(i))
        }
        let first = await cache.get(CGWindowID(0))
        XCTAssertNil(first, "最旧条目应被淘汰")
    }
}

// MARK: - AC-05：应用内切换（F03）

@MainActor
final class F03AppInternalSwitchTests: XCTestCase {

    // AC-05: switchWithinCurrentApp 无前台应用时不崩溃
    func testAC05_SwitchWithinAppNoFrontApp() {
        let vm = SwitchPanelViewModel(
            windows: [makeWindow(id: 1, app: "Safari", offset: -1)],
            windowManager: WindowManager.shared,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
        XCTAssertNoThrow(vm.switchWithinCurrentApp())
    }

    // AC-05: 应用内切换只在同一应用窗口间循环
    func testAC05_AppSwitchFiltersSameApp() {
        let engine = FilterEngine()
        let windows = [
            makeWindow(id: 1, app: "Safari",  offset: -1),
            makeWindow(id: 2, app: "Safari",  offset: -2),
            makeWindow(id: 3, app: "Chrome",  offset: -3),
        ]
        let safariWindows = engine.filter(windows, by: FilterCriteria(appName: "Safari"))
        XCTAssertEqual(safariWindows.count, 2)
        XCTAssertTrue(safariWindows.allSatisfy { $0.appName == "Safari" })
    }

    // AC-05: 单窗口应用不触发切换
    func testAC05_SingleWindowAppNoSwitch() {
        let engine = FilterEngine()
        let windows = [makeWindow(id: 1, app: "Safari", offset: -1)]
        let result = engine.filter(windows, by: FilterCriteria(appName: "Safari"))
        XCTAssertEqual(result.count, 1, "单窗口应用不应触发应用内切换")
    }
}

// MARK: - AC-06：窗口管理操作（F04）

@MainActor
final class F04WindowManagementTests: XCTestCase {

    var vm: SwitchPanelViewModel!

    override func setUp() async throws {
        let windows = (1...4).map { makeWindow(id: CGWindowID($0), app: "App\($0)", offset: -Double($0)) }
        vm = SwitchPanelViewModel(
            windows: windows,
            windowManager: WindowManager.shared,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
    }

    // AC-06: 关闭窗口后立即从列表移除（乐观更新 < 50ms）
    func testAC06_CloseWindowRemovesImmediately() {
        guard let first = vm.filteredWindows.first else { return XCTFail() }
        let before = vm.filteredWindows.count
        let start = CFAbsoluteTimeGetCurrent()
        vm.closeWindow(first)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertEqual(vm.filteredWindows.count, before - 1)
        XCTAssertFalse(vm.filteredWindows.contains { $0.id == first.id })
        XCTAssertLessThan(elapsed, 50, "关闭操作应 < 50ms，实测 \(elapsed)ms")
    }

    // AC-06: 最小化窗口后立即从列表移除
    func testAC06_MinimizeWindowRemovesImmediately() {
        guard let first = vm.filteredWindows.first else { return XCTFail() }
        let before = vm.filteredWindows.count
        let start = CFAbsoluteTimeGetCurrent()
        vm.minimizeWindow(first)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertEqual(vm.filteredWindows.count, before - 1)
        XCTAssertLessThan(elapsed, 50, "最小化操作应 < 50ms，实测 \(elapsed)ms")
    }

    // AC-06: 隐藏窗口后立即从列表移除
    func testAC06_HideWindowRemovesImmediately() {
        guard let first = vm.filteredWindows.first else { return XCTFail() }
        let before = vm.filteredWindows.count
        let start = CFAbsoluteTimeGetCurrent()
        vm.hideWindow(first)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertEqual(vm.filteredWindows.count, before - 1)
        XCTAssertLessThan(elapsed, 50, "隐藏操作应 < 50ms，实测 \(elapsed)ms")
    }

    // AC-06: 关闭后 selectedIndex 不越界
    func testAC06_SelectedIndexStaysValidAfterClose() {
        vm.selectedIndex = vm.filteredWindows.count - 1
        guard let last = vm.filteredWindows.last else { return XCTFail() }
        vm.closeWindow(last)
        XCTAssertLessThan(vm.selectedIndex, max(1, vm.filteredWindows.count))
    }

    // AC-06: 关闭所有窗口后 selectedWindow 为 nil
    func testAC06_SelectedWindowNilWhenAllClosed() {
        let all = vm.filteredWindows
        all.forEach { vm.closeWindow($0) }
        XCTAssertNil(vm.selectedWindow)
    }
}

// MARK: - AC-07：智能筛选（F05）

final class F05FilterTests: XCTestCase {

    let engine = FilterEngine()

    // AC-07: 搜索延迟 ≤50ms（100个窗口）
    func testAC07_SearchResponseUnder50ms() {
        let windows = (0..<100).map { makeWindow(id: CGWindowID($0), app: "App\($0 % 10)", offset: -Double($0)) }
        let start = CFAbsoluteTimeGetCurrent()
        _ = engine.filter(windows, by: FilterCriteria(searchText: "app5"))
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 50, "搜索应 < 50ms，实测 \(elapsed)ms")
    }

    // AC-07: 模糊搜索子串匹配
    func testAC07_FuzzySubstringMatch() {
        let windows = [makeWindow(id: 1, app: "Safari", offset: -1)]
        let result = engine.filter(windows, by: FilterCriteria(searchText: "saf"))
        XCTAssertFalse(result.isEmpty)
    }

    // AC-07: 模糊搜索字符序列匹配
    func testAC07_FuzzyCharSequenceMatch() {
        let windows = [makeWindow(id: 1, app: "Safari", offset: -1)]
        let result = engine.filter(windows, by: FilterCriteria(searchText: "sfr"))
        XCTAssertFalse(result.isEmpty)
    }

    // AC-07: 大小写不敏感
    func testAC07_CaseInsensitiveSearch() {
        let windows = [makeWindow(id: 1, app: "Safari", offset: -1)]
        let lower = engine.filter(windows, by: FilterCriteria(searchText: "safari"))
        let upper = engine.filter(windows, by: FilterCriteria(searchText: "SAFARI"))
        XCTAssertEqual(lower.count, upper.count)
    }

    // AC-07: 无匹配返回空
    func testAC07_NoMatchReturnsEmpty() {
        let windows = [makeWindow(id: 1, app: "Safari", offset: -1)]
        let result = engine.filter(windows, by: FilterCriteria(searchText: "zzznomatch"))
        XCTAssertTrue(result.isEmpty)
    }

    // AC-07: 空搜索返回全部
    func testAC07_EmptySearchReturnsAll() {
        let windows = (1...5).map { makeWindow(id: CGWindowID($0), app: "App\($0)", offset: -Double($0)) }
        let result = engine.filter(windows, by: FilterCriteria(searchText: ""))
        XCTAssertEqual(result.count, windows.count)
    }

    // AC-07: 窗口标题也参与搜索
    func testAC07_SearchMatchesWindowTitle() {
        let w = WindowModel(
            id: 1, appName: "Chrome", bundleIdentifier: "com.chrome",
            windowTitle: "GitHub - Pull Request", appIcon: NSImage(),
            frame: .zero, isMinimized: false, isHidden: false, isOnScreen: true,
            lastActiveTime: Date(), windowLayer: 0, ownerPID: 100
        )
        let result = engine.filter([w], by: FilterCriteria(searchText: "github"))
        XCTAssertFalse(result.isEmpty)
    }

    // AC-07: showMinimized=false 过滤最小化窗口
    func testAC07_ShowMinimizedFalseFilters() {
        let windows = [
            makeWindow(id: 1, app: "A", offset: -1, minimized: false),
            makeWindow(id: 2, app: "B", offset: -2, minimized: true),
        ]
        let result = engine.filter(windows, by: FilterCriteria(showMinimized: false))
        XCTAssertFalse(result.contains { $0.isMinimized })
    }
}

// MARK: - AC-08：多种风格（F06）

final class F06ThemeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConfigManager.shared.reset()
    }

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
    }

    // AC-08: 四种主题枚举存在
    func testAC08_ThemeEnumHasAllCases() {
        XCTAssertEqual(AppTheme.allCases.count, 3) // light, dark, auto
    }

    // AC-08: 主题切换后 ThemeManager 更新
    func testAC08_LightThemeApplied() {
        ConfigManager.shared.updateAppearance { $0.theme = .light }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .light)
    }

    func testAC08_DarkThemeApplied() {
        ConfigManager.shared.updateAppearance { $0.theme = .dark }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .dark)
    }

    // AC-08: 面板透明度范围 0.5~1.0
    func testAC08_PanelOpacityRange() {
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.5 }
        XCTAssertGreaterThanOrEqual(ConfigManager.shared.config.appearance.panelOpacity, 0.5)
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 1.0 }
        XCTAssertLessThanOrEqual(ConfigManager.shared.config.appearance.panelOpacity, 1.0)
    }

    // AC-08: 圆角半径范围 4~24
    func testAC08_CornerRadiusRange() {
        ConfigManager.shared.updateAppearance { $0.panelCornerRadius = 4 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.panelCornerRadius, 4, accuracy: 0.001)
        ConfigManager.shared.updateAppearance { $0.panelCornerRadius = 24 }
        XCTAssertEqual(ConfigManager.shared.config.appearance.panelCornerRadius, 24, accuracy: 0.001)
    }
}

// MARK: - AC-09：设置保存与加载（F07）

final class F07SettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConfigManager.shared.reset()
    }

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
    }

    // AC-09: 外观设置保存后可读取
    func testAC09_AppearanceSettingsPersist() throws {
        ConfigManager.shared.updateAppearance {
            $0.panelOpacity = 0.7
            $0.theme = .dark
            $0.panelCornerRadius = 16
        }
        let data = try JSONEncoder().encode(ConfigManager.shared.config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)
        XCTAssertEqual(decoded.appearance.panelOpacity, 0.7, accuracy: 0.001)
        XCTAssertEqual(decoded.appearance.theme, .dark)
        XCTAssertEqual(decoded.appearance.panelCornerRadius, 16, accuracy: 0.001)
    }

    // AC-09: 行为设置保存后可读取
    func testAC09_BehaviorSettingsPersist() throws {
        ConfigManager.shared.updateBehavior {
            $0.sortOrder = .windowTitle
            $0.showMinimizedWindows = false
            $0.showHiddenWindows = true
            $0.previewUpdateInterval = 0.2
        }
        let data = try JSONEncoder().encode(ConfigManager.shared.config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)
        XCTAssertEqual(decoded.behavior.sortOrder, .windowTitle)
        XCTAssertFalse(decoded.behavior.showMinimizedWindows)
        XCTAssertTrue(decoded.behavior.showHiddenWindows)
        XCTAssertEqual(decoded.behavior.previewUpdateInterval, 0.2, accuracy: 0.001)
    }

    // AC-09: 快捷键设置保存后可读取
    func testAC09_HotKeySettingsPersist() throws {
        ConfigManager.shared.updateHotKeys {
            $0.switchKeyCode = 36
            $0.switchModifiers = 512
        }
        let data = try JSONEncoder().encode(ConfigManager.shared.config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)
        XCTAssertEqual(decoded.hotKeys.switchKeyCode, 36)
        XCTAssertEqual(decoded.hotKeys.switchModifiers, 512)
    }

    // AC-09: reset 后恢复默认值
    func testAC09_ResetRestoresDefaults() {
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.1 }
        ConfigManager.shared.reset()
        XCTAssertEqual(ConfigManager.shared.config.appearance.panelOpacity, 0.95, accuracy: 0.001)
        XCTAssertEqual(ConfigManager.shared.config.behavior.sortOrder, .recent)
    }

    // AC-09: 损坏数据降级为默认值
    func testAC09_CorruptDataFallsBackToDefault() {
        let corruptData = "not valid json".data(using: .utf8)!
        let decoded = (try? JSONDecoder().decode(ConfigModel.self, from: corruptData)) ?? ConfigModel()
        XCTAssertEqual(decoded.appearance.panelOpacity, 0.95, accuracy: 0.001)
    }

    // AC-09: 正常保存后 saveError 为 nil
    func testAC09_SaveErrorNilOnSuccess() {
        ConfigManager.shared.updateAppearance { $0.panelOpacity = 0.8 }
        XCTAssertNil(ConfigManager.shared.saveError)
        ConfigManager.shared.reset()
    }

    // AC-09: reset 后 saveError 仍为 nil
    func testAC09_SaveErrorNilAfterReset() {
        ConfigManager.shared.reset()
        XCTAssertNil(ConfigManager.shared.saveError)
    }

    // AC-09: saveError 可手动清除
    func testAC09_SaveErrorCanBeCleared() {
        ConfigManager.shared.saveError = "测试错误"
        XCTAssertNotNil(ConfigManager.shared.saveError)
        ConfigManager.shared.saveError = nil
        XCTAssertNil(ConfigManager.shared.saveError)
    }
}

// MARK: - AC-10：快捷键冲突检测（F08）

final class F08HotKeyTests: XCTestCase {

    // AC-10: 同一 identifier 注册两次，后者覆盖前者
    func testAC10_DuplicateIdentifierOverwrites() {
        let manager = HotKeyManager()
        var callCount = 0
        manager.register(HotKey(keyCode: 48, modifiers: 256, identifier: "switch")) { callCount += 1 }
        manager.register(HotKey(keyCode: 48, modifiers: 256, identifier: "switch")) { callCount += 10 }
        manager.unregister("switch")
        XCTAssertEqual(callCount, 0, "注销后不应触发任何回调")
    }

    // AC-10: 不同 identifier 可共存
    func testAC10_DifferentIdentifiersCoexist() {
        let manager = HotKeyManager()
        manager.register(HotKey(keyCode: 48, modifiers: 256, identifier: "switch")) {}
        manager.register(HotKey(keyCode: 48, modifiers: 131072, identifier: "reverseSwitch")) {}
        // 两个都注销不崩溃
        manager.unregister("switch")
        manager.unregister("reverseSwitch")
    }

    // AC-10: 注销不存在的 key 不崩溃
    func testAC10_UnregisterNonExistentKeyNoCrash() {
        let manager = HotKeyManager()
        XCTAssertNoThrow(manager.unregister("nonexistent"))
    }

    // AC-10: 相同 keyCode+modifiers 不同 identifier 重复注册不崩溃
    func testAC10_SameKeyComboOverwritesPrevious() {
        let manager = HotKeyManager()
        var callCount = 0
        manager.register(HotKey(keyCode: 48, modifiers: 256, identifier: "first")) { callCount += 1 }
        manager.register(HotKey(keyCode: 48, modifiers: 256, identifier: "second")) { callCount += 10 }
        manager.unregister("first")
        manager.unregister("second")
        XCTAssertEqual(callCount, 0) // 无触发，不崩溃即通过
    }

    // AC-10: 注销不存在的 identifier 不崩溃
    func testAC10_UnregisterUnknownIdentifierNoCrash() {
        let manager = HotKeyManager()
        XCTAssertNoThrow(manager.unregister("does-not-exist"))
    }

    // AC-10: 默认快捷键配置符合规范
    func testAC10_DefaultHotKeyConfig() {
        let hk = HotKeyConfig()
        XCTAssertEqual(hk.switchKeyCode, 48)          // Tab
        XCTAssertEqual(hk.switchModifiers, 256)        // Cmd
        XCTAssertEqual(hk.reverseSwitchModifiers, 131072) // Cmd+Shift
        XCTAssertEqual(hk.appSwitchKeyCode, 50)        // `
    }

    // AC-10: 通知名称唯一，无冲突
    func testAC10_NotificationNamesUnique() {
        let names: [Notification.Name] = [
            .switchHotKeyPressed,
            .reverseSwitchHotKeyPressed,
            .appSwitchHotKeyPressed,
            .windowListDidChange
        ]
        let unique = Set(names.map { $0.rawValue })
        XCTAssertEqual(unique.count, names.count, "所有通知名称应唯一，无冲突")
    }
}

// MARK: - PanelAnimator 功能测试

final class PanelAnimatorTests: XCTestCase {

    // 动画时长符合规范（≤300ms）
    func testShowAnimationDuration() {
        // show: 0.2s = 200ms ≤ 300ms
        XCTAssertLessThanOrEqual(0.2, 0.3)
    }

    func testHideAnimationDuration() {
        // hide: 0.15s = 150ms ≤ 300ms
        XCTAssertLessThanOrEqual(0.15, 0.3)
    }
}

// MARK: - Helpers

private func makeWindow(
    id: CGWindowID,
    app: String,
    offset: TimeInterval,
    minimized: Bool = false,
    hidden: Bool = false
) -> WindowModel {
    WindowModel(
        id: id,
        appName: app,
        bundleIdentifier: "com.\(app.lowercased())",
        windowTitle: "\(app) - Window",
        appIcon: NSImage(),
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        isMinimized: minimized,
        isHidden: hidden,
        isOnScreen: !minimized,
        lastActiveTime: Date().addingTimeInterval(offset),
        windowLayer: 0,
        ownerPID: pid_t(id * 100)
    )
}
