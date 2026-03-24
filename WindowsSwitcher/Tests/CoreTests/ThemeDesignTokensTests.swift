import XCTest
import SwiftUI
import Combine
@testable import WindowsSwitcher

// MARK: - T-037 ThemeManager 测试

final class ThemeManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConfigManager.shared.reset()
    }

    override func tearDown() {
        ConfigManager.shared.reset()
        super.tearDown()
    }

    func testSharedInstanceExists() {
        XCTAssertNotNil(ThemeManager.shared)
    }

    func testApplyLightTheme() {
        ConfigManager.shared.updateAppearance { $0.theme = .light }
        // Allow Combine pipeline to propagate
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .light)
    }

    func testApplyDarkTheme() {
        ConfigManager.shared.updateAppearance { $0.theme = .dark }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .dark)
    }

    func testApplyAutoThemeDoesNotCrash() {
        ConfigManager.shared.updateAppearance { $0.theme = .auto }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        // auto maps to system appearance — just verify no crash and valid value
        let scheme = ThemeManager.shared.effectiveColorScheme
        XCTAssertTrue(scheme == .light || scheme == .dark)
    }

    func testThemeChangePublishesUpdate() {
        let exp = expectation(description: "effectiveColorScheme published")
        var cancellable: AnyCancellable?
        cancellable = ThemeManager.shared.$effectiveColorScheme
            .dropFirst()
            .sink { _ in exp.fulfill(); cancellable?.cancel() }
        ConfigManager.shared.updateAppearance { $0.theme = .dark }
        waitForExpectations(timeout: 1.0)
    }

    func testSwitchBetweenThemes() {
        ConfigManager.shared.updateAppearance { $0.theme = .light }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .light)

        ConfigManager.shared.updateAppearance { $0.theme = .dark }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .dark)

        ConfigManager.shared.updateAppearance { $0.theme = .light }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(ThemeManager.shared.effectiveColorScheme, .light)
    }
}

// MARK: - DesignTokens 完整规格测试

final class DesignTokensTests: XCTestCase {

    // MARK: - Spacing

    func testSpacingValues() {
        XCTAssertEqual(DesignTokens.Spacing.xs, 4)
        XCTAssertEqual(DesignTokens.Spacing.sm, 8)
        XCTAssertEqual(DesignTokens.Spacing.md, 12)
        XCTAssertEqual(DesignTokens.Spacing.lg, 16)
        XCTAssertEqual(DesignTokens.Spacing.xl, 24)
        XCTAssertEqual(DesignTokens.Spacing.xxl, 32)
    }

    func testSpacingIsAscending() {
        let values: [CGFloat] = [
            DesignTokens.Spacing.xs,
            DesignTokens.Spacing.sm,
            DesignTokens.Spacing.md,
            DesignTokens.Spacing.lg,
            DesignTokens.Spacing.xl,
            DesignTokens.Spacing.xxl
        ]
        for i in 0..<values.count - 1 {
            XCTAssertLessThan(values[i], values[i + 1], "Spacing 应严格递增")
        }
    }

    // MARK: - CornerRadius

    func testCornerRadiusValues() {
        XCTAssertEqual(DesignTokens.CornerRadius.sm, 4)
        XCTAssertEqual(DesignTokens.CornerRadius.md, 8)
        XCTAssertEqual(DesignTokens.CornerRadius.lg, 12)
        XCTAssertEqual(DesignTokens.CornerRadius.button, 6)
        XCTAssertEqual(DesignTokens.CornerRadius.panel, 10)
        XCTAssertEqual(DesignTokens.CornerRadius.preview, 6)
        XCTAssertEqual(DesignTokens.CornerRadius.icon, 8)
        XCTAssertEqual(DesignTokens.CornerRadius.windowItem, 10)
    }

    // MARK: - Panel

    func testPanelDimensions() {
        XCTAssertEqual(DesignTokens.Panel.width, 720)
        XCTAssertEqual(DesignTokens.Panel.height, 480)
        XCTAssertEqual(DesignTokens.Panel.padding, 16)
        XCTAssertEqual(DesignTokens.Panel.cornerRadius, 10)
        XCTAssertEqual(DesignTokens.Panel.shadowRadius, 20)
        XCTAssertEqual(DesignTokens.Panel.shadowY, 8)
    }

    func testPanelAspectRatio() {
        // 720:480 = 3:2
        let ratio = DesignTokens.Panel.width / DesignTokens.Panel.height
        XCTAssertEqual(ratio, 1.5, accuracy: 0.01)
    }

    // MARK: - WindowItem

    func testWindowItemDimensions() {
        XCTAssertEqual(DesignTokens.WindowItem.width, 140)
        XCTAssertEqual(DesignTokens.WindowItem.height, 140)
        XCTAssertEqual(DesignTokens.WindowItem.iconSize, 32)
        XCTAssertEqual(DesignTokens.WindowItem.iconCornerRadius, 8)
        XCTAssertEqual(DesignTokens.WindowItem.previewWidth, 124)
        XCTAssertEqual(DesignTokens.WindowItem.previewHeight, 70)
        XCTAssertEqual(DesignTokens.WindowItem.previewCornerRadius, 6)
        XCTAssertEqual(DesignTokens.WindowItem.spacing, 12)
        XCTAssertEqual(DesignTokens.WindowItem.titleFontSize, 13)
        XCTAssertEqual(DesignTokens.WindowItem.subtitleFontSize, 11)
    }

    func testPreviewIs16by9Ratio() {
        // 124:70 ≈ 16:9
        let ratio = DesignTokens.WindowItem.previewWidth / DesignTokens.WindowItem.previewHeight
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.05, "预览图应为 16:9 比例")
    }

    func testPreviewFitsInsideWindowItem() {
        XCTAssertLessThanOrEqual(DesignTokens.WindowItem.previewWidth, DesignTokens.WindowItem.width)
        XCTAssertLessThanOrEqual(DesignTokens.WindowItem.previewHeight, DesignTokens.WindowItem.height)
    }

    func testIconFitsInsideWindowItem() {
        XCTAssertLessThanOrEqual(DesignTokens.WindowItem.iconSize, DesignTokens.WindowItem.width)
    }
}

// MARK: - WindowModel 属性完整测试

final class WindowModelPropertyTests: XCTestCase {

    private func makeWindow(
        id: CGWindowID = 1,
        appName: String = "TestApp",
        bundleID: String = "com.test",
        title: String = "Test Window",
        minimized: Bool = false,
        hidden: Bool = false,
        onScreen: Bool = true,
        layer: Int = 0,
        pid: pid_t = 1234
    ) -> WindowModel {
        WindowModel(
            id: id, appName: appName, bundleIdentifier: bundleID,
            windowTitle: title, appIcon: NSImage(),
            frame: CGRect(x: 10, y: 20, width: 800, height: 600),
            isMinimized: minimized, isHidden: hidden, isOnScreen: onScreen,
            lastActiveTime: Date(), windowLayer: layer, ownerPID: pid
        )
    }

    func testAllPropertiesStored() {
        let w = makeWindow(id: 42, appName: "Safari", bundleID: "com.apple.safari",
                           title: "Apple", minimized: true, hidden: false,
                           onScreen: false, layer: 0, pid: 9999)
        XCTAssertEqual(w.id, 42)
        XCTAssertEqual(w.appName, "Safari")
        XCTAssertEqual(w.bundleIdentifier, "com.apple.safari")
        XCTAssertEqual(w.windowTitle, "Apple")
        XCTAssertTrue(w.isMinimized)
        XCTAssertFalse(w.isHidden)
        XCTAssertFalse(w.isOnScreen)
        XCTAssertEqual(w.windowLayer, 0)
        XCTAssertEqual(w.ownerPID, 9999)
        XCTAssertEqual(w.frame, CGRect(x: 10, y: 20, width: 800, height: 600))
    }

    func testEqualityByID() {
        let w1 = makeWindow(id: 1, appName: "Safari")
        let w2 = makeWindow(id: 1, appName: "Chrome") // same id, different name
        XCTAssertEqual(w1, w2, "WindowModel 相等性仅依赖 id")
    }

    func testInequalityByID() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        XCTAssertNotEqual(w1, w2)
    }

    func testIdentifiableID() {
        let w = makeWindow(id: 77)
        XCTAssertEqual(w.id, 77)
    }

    func testMinimizedAndHiddenAreMutuallyIndependent() {
        let minimizedOnly = makeWindow(minimized: true, hidden: false)
        let hiddenOnly = makeWindow(minimized: false, hidden: true)
        let both = makeWindow(minimized: true, hidden: true)
        XCTAssertTrue(minimizedOnly.isMinimized)
        XCTAssertFalse(minimizedOnly.isHidden)
        XCTAssertFalse(hiddenOnly.isMinimized)
        XCTAssertTrue(hiddenOnly.isHidden)
        XCTAssertTrue(both.isMinimized)
        XCTAssertTrue(both.isHidden)
    }

    func testLastActiveTimeIsStored() {
        let date = Date(timeIntervalSince1970: 1000)
        let w = WindowModel(
            id: 1, appName: "App", bundleIdentifier: "com.app",
            windowTitle: "Win", appIcon: NSImage(),
            frame: .zero, isMinimized: false, isHidden: false, isOnScreen: true,
            lastActiveTime: date, windowLayer: 0, ownerPID: 1
        )
        XCTAssertEqual(w.lastActiveTime, date)
    }
}

// MARK: - FilterCriteria 默认值与边界测试

final class FilterCriteriaTests: XCTestCase {

    func testDefaultValues() {
        let c = FilterCriteria()
        XCTAssertEqual(c.searchText, "")
        XCTAssertTrue(c.showMinimized)
        XCTAssertFalse(c.showHidden)
        XCTAssertNil(c.appName)
        XCTAssertFalse(c.currentSpaceOnly)
    }

    func testCustomInit() {
        let c = FilterCriteria(searchText: "test", showMinimized: false,
                               showHidden: true, appName: "Safari", currentSpaceOnly: true)
        XCTAssertEqual(c.searchText, "test")
        XCTAssertFalse(c.showMinimized)
        XCTAssertTrue(c.showHidden)
        XCTAssertEqual(c.appName, "Safari")
        XCTAssertTrue(c.currentSpaceOnly)
    }

    func testEmptySearchMatchesAll() {
        let engine = FilterEngine()
        let windows = (1...5).map { makeWindow(id: CGWindowID($0), app: "App\($0)") }
        let result = engine.filter(windows, by: FilterCriteria(searchText: ""))
        XCTAssertEqual(result.count, windows.count)
    }

    func testAppNameFilterNilMatchesAll() {
        let engine = FilterEngine()
        let windows = [makeWindow(id: 1, app: "Safari"), makeWindow(id: 2, app: "Chrome")]
        let result = engine.filter(windows, by: FilterCriteria(appName: nil))
        XCTAssertEqual(result.count, 2)
    }

    func testAppNameFilterExact() {
        let engine = FilterEngine()
        let windows = [makeWindow(id: 1, app: "Safari"), makeWindow(id: 2, app: "Chrome")]
        let result = engine.filter(windows, by: FilterCriteria(appName: "Safari"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.appName, "Safari")
    }

    func testShowHiddenFalseExcludesHidden() {
        let engine = FilterEngine()
        let windows = [
            makeWindow(id: 1, app: "A", hidden: false),
            makeWindow(id: 2, app: "B", hidden: true)
        ]
        let result = engine.filter(windows, by: FilterCriteria(showHidden: false))
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.first!.isHidden)
    }

    func testShowHiddenTrueIncludesHidden() {
        let engine = FilterEngine()
        let windows = [
            makeWindow(id: 1, app: "A", hidden: false),
            makeWindow(id: 2, app: "B", hidden: true)
        ]
        let result = engine.filter(windows, by: FilterCriteria(showMinimized: true, showHidden: true))
        XCTAssertEqual(result.count, 2)
    }

    private func makeWindow(id: CGWindowID, app: String, hidden: Bool = false) -> WindowModel {
        WindowModel(
            id: id, appName: app, bundleIdentifier: "com.\(app.lowercased())",
            windowTitle: app, appIcon: NSImage(),
            frame: .zero, isMinimized: false, isHidden: hidden, isOnScreen: true,
            lastActiveTime: Date(), windowLayer: 0, ownerPID: pid_t(id)
        )
    }
}

// MARK: - SwitchPanelViewModel 通知驱动路径测试

@MainActor
final class SwitchPanelViewModelNotificationTests: XCTestCase {

    var viewModel: SwitchPanelViewModel!

    override func setUp() async throws {
        let windows = (1...5).map { i -> WindowModel in
            WindowModel(
                id: CGWindowID(i), appName: "App\(i)", bundleIdentifier: "com.app\(i)",
                windowTitle: "Window \(i)", appIcon: NSImage(),
                frame: .zero, isMinimized: false, isHidden: false, isOnScreen: true,
                lastActiveTime: Date().addingTimeInterval(-Double(i)),
                windowLayer: 0, ownerPID: pid_t(i * 100)
            )
        }
        viewModel = SwitchPanelViewModel(
            windows: windows,
            windowManager: WindowManager.shared,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
    }

    // switchHotKeyPressed 通知触发 selectNext
    func testSwitchNotificationAdvancesSelection() {
        let before = viewModel.selectedIndex
        NotificationCenter.default.post(name: .switchHotKeyPressed, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(viewModel.selectedIndex, (before + 1) % viewModel.filteredWindows.count)
    }

    // reverseSwitchHotKeyPressed 通知触发 selectPrevious
    func testReverseSwitchNotificationDecreasesSelection() {
        viewModel.selectedIndex = 2
        NotificationCenter.default.post(name: .reverseSwitchHotKeyPressed, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(viewModel.selectedIndex, 1)
    }

    // appSwitchHotKeyPressed 通知不崩溃
    func testAppSwitchNotificationDoesNotCrash() {
        XCTAssertNoThrow(
            NotificationCenter.default.post(name: .appSwitchHotKeyPressed, object: nil)
        )
    }

    // selectedWindow nil when empty
    func testSelectedWindowNilWhenEmpty() {
        let emptyVM = SwitchPanelViewModel(
            windows: [],
            windowManager: WindowManager.shared,
            previewGenerator: PreviewGenerator(),
            filterEngine: FilterEngine()
        )
        XCTAssertNil(emptyVM.selectedWindow)
    }

    // selectedWindow returns correct window
    func testSelectedWindowMatchesIndex() {
        viewModel.selectedIndex = 2
        XCTAssertEqual(viewModel.selectedWindow?.id, viewModel.filteredWindows[2].id)
    }

    // selectNext wraps at end
    func testSelectNextWrapsAtEnd() {
        viewModel.selectedIndex = viewModel.filteredWindows.count - 1
        viewModel.selectNext()
        XCTAssertEqual(viewModel.selectedIndex, 0)
    }

    // selectPrevious wraps at start
    func testSelectPreviousWrapsAtStart() {
        viewModel.selectedIndex = 0
        viewModel.selectPrevious()
        XCTAssertEqual(viewModel.selectedIndex, viewModel.filteredWindows.count - 1)
    }

    // applyFilter respects showMinimized config
    func testApplyFilterRespectsShowMinimizedConfig() {
        ConfigManager.shared.updateBehavior { $0.showMinimizedWindows = false }
        viewModel.applyFilter()
        XCTAssertFalse(viewModel.filteredWindows.contains { $0.isMinimized })
        ConfigManager.shared.updateBehavior { $0.showMinimizedWindows = true }
    }

    // searchText empty restores all
    func testSearchTextEmptyRestoresAll() {
        let total = viewModel.filteredWindows.count
        viewModel.searchText = "zzznomatch"
        XCTAssertTrue(viewModel.filteredWindows.isEmpty)
        viewModel.searchText = ""
        XCTAssertEqual(viewModel.filteredWindows.count, total)
    }
}
