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
    var switchModifiers: UInt32 = 256    // Cmd
    var reverseSwitchModifiers: UInt32 = 131072 // Cmd+Shift
    var appSwitchKeyCode: UInt32 = 50    // `
    var appSwitchModifiers: UInt32 = 256
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
}

struct DockPreviewConfig: Codable, Equatable {
    var enabled: Bool = true                    // 是否启用 Dock 预览
    var hoverDelay: Double = 0.35              // 悬停触发延迟（秒）
    var hideDelay: Double = 0.2               // 鼠标移出后隐藏延迟（秒）
    var maxPreviewCount: Int = 4               // 最大预览窗口数量
    var previewWidth: Double = 104            // 预览图宽度
    var previewHeight: Double = 58             // 预览图高度（16:9）
    var showAnimation: Bool = true             // 是否显示动画
}

struct ConfigModel: Codable, Equatable {
    var hotKeys: HotKeyConfig = HotKeyConfig()
    var appearance: AppearanceConfig = AppearanceConfig()
    var behavior: BehaviorConfig = BehaviorConfig()
    var dockPreview: DockPreviewConfig = DockPreviewConfig()
}
