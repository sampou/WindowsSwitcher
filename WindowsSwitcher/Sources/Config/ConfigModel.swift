import Foundation

enum AppTheme: String, Codable, Equatable, CaseIterable {
    case light, dark, auto
}

enum SortOrder: String, Codable, Equatable, CaseIterable {
    case recent, appName, windowTitle
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
