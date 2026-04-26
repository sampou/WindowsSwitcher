import Foundation

enum AppTheme: String, Codable, Equatable, CaseIterable {
    case light, dark, auto
}

enum SortOrder: String, Codable, Equatable, CaseIterable {
    case recent, appName, windowTitle, appGroup
}

enum PreviewSize: String, Codable, Equatable, CaseIterable {
    case small = "小"
    case medium = "中"
    case large = "大"

    // 预览窗口尺寸
    var dimensions: (width: CGFloat, height: CGFloat) {
        switch self {
        case .small: return (80, 45)
        case .medium: return (114, 64)
        case .large: return (160, 90)
        }
    }

    // 窗口项整体尺寸
    var itemDimensions: (width: CGFloat, height: CGFloat) {
        switch self {
        case .small: return (100, 90)
        case .medium: return (130, 110)
        case .large: return (180, 150)
        }
    }
}

struct HotKeyConfig: Codable, Equatable {
    var switchKeyCode: UInt32 = 48       // Tab
    var switchModifiers: UInt32 = 2048   // Option (optionKey = 2048)
    var reverseSwitchModifiers: UInt32 = 2560 // Option+Shift (2048 + 512)
    var appSwitchKeyCode: UInt32 = 50    // ` (Grave)
    var appSwitchModifiers: UInt32 = 2048 // Option
    var appSwitchReverseKeyCode: UInt32 = 50  // ` (Grave)
    var appSwitchReverseModifiers: UInt32 = 2560 // Option+Shift
    var appSwitchEnabled: Bool = true    // 是否启用同应用窗口切换快捷键
}

struct AppearanceConfig: Codable, Equatable {
    var panelOpacity: Double = 0.95
    var panelCornerRadius: Double = 12
    var previewWidth: Double = 640
    var previewHeight: Double = 360
    var previewSize: PreviewSize = .medium  // 预览窗口大小
    var switcherColumns: Int = 0  // 切换器每行列数，0表示自动计算
    var theme: AppTheme = .auto
}

struct BehaviorConfig: Codable, Equatable {
    var sortOrder: SortOrder = .recent
    var showMinimizedWindows: Bool = true
    var showHiddenWindows: Bool = false
    var previewUpdateInterval: Double = 0.1
    var panelDisplayDelay: Double = 0.0
    var defaultSelectSecond: Bool = false  // 打开切换面板时默认选中第二个窗口
    var showBackgroundPreview: Bool = true  // 是否显示背景预览
    var launchAtLogin: Bool = false  // 开机自动启动
}

struct DockPreviewConfig: Codable, Equatable {
    var enabled: Bool = true                    // 是否启用 Dock 预览
    var hoverDelay: Double = 0.05              // 悬停触发延迟（秒）
    var hideDelay: Double = 0.1                // 鼠标移出后隐藏延迟（秒）
    var maxPreviewCount: Int = 4               // 最大预览窗口数量
    var previewWidth: Double = 104            // 预览图宽度
    var previewHeight: Double = 58             // 预览图高度（16:9）
    var showAnimation: Bool = true             // 是否显示动画
    var verticalSpacing: Double = 0            // 预览窗口与程序坞的垂直间距（像素），0 表示自动计算
    var horizontalSpacing: Double = 0          // 预览窗口与程序坞的水平间距（像素），0 表示自动计算
    var showAppIcon: Bool = true               // 是否显示应用图标
}

struct UpdateConfig: Codable, Equatable {
    var autoCheckEnabled: Bool = false         // 是否自动检查更新
    var autoDownloadEnabled: Bool = false      // 是否自动下载安装
    var silentInstallEnabled: Bool = false     // 是否启用静默安装
    var checkInterval: Double = 86400          // 检查间隔（秒），默认 24 小时
    var apiURL: String = "https://api.github.com/repos/sampou/WindowsSwitcher/releases/latest"  // 版本检查 API 地址
    var releasesPageURL: String = "https://github.com/sampou/WindowsSwitcher/releases"  // 发布页面地址
    var githubToken: String = ""               // GitHub Token（可选，用于提高 API 限制）
}

struct ConfigModel: Codable, Equatable {
    var hotKeys: HotKeyConfig = HotKeyConfig()
    var appearance: AppearanceConfig = AppearanceConfig()
    var behavior: BehaviorConfig = BehaviorConfig()
    var dockPreview: DockPreviewConfig = DockPreviewConfig()
    var update: UpdateConfig = UpdateConfig()
}
