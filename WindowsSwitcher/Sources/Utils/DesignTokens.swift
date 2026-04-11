import SwiftUI
import AppKit

// ============================================
// 颜色系统 - 使用 NSColor 系统颜色自动适配深浅色
// ============================================
struct DesignTokens {
    struct Colors {
        // 主强调色 - 跟随系统
        static let accent = Color.accentColor
        static let accentLight = Color.accentColor.opacity(0.15)
        static let accentHover = Color.accentColor.opacity(0.8)

        // 背景色
        static let background = Color(NSColor.windowBackgroundColor)
        static let secondaryBackground = Color(NSColor.controlBackgroundColor)
        static let tertiaryBackground = Color(NSColor.underPageBackgroundColor)

        // 文字色
        static let label = Color(NSColor.labelColor)
        static let secondaryLabel = Color(NSColor.secondaryLabelColor)
        static let tertiaryLabel = Color(NSColor.tertiaryLabelColor)

        // 分隔/边框
        static let separator = Color(NSColor.separatorColor)

        // 选中色
        static let selectedBackground = Color(NSColor.selectedContentBackgroundColor)
        static let selectedControl = Color(NSColor.selectedControlColor)
        static let selectedBorder = Color.accentColor

        // 兼容旧代码的 Light/Dark 结构
        struct Light {
            static let background = Color(NSColor.windowBackgroundColor)
            static let secondaryBackground = Color(NSColor.controlBackgroundColor)
            static let border = Color(NSColor.separatorColor)
            static let primaryText = Color(NSColor.labelColor)
            static let secondaryText = Color(NSColor.secondaryLabelColor)
        }
        struct Dark {
            static let background = Color(NSColor.windowBackgroundColor)
            static let secondaryBackground = Color(NSColor.controlBackgroundColor)
            static let border = Color(NSColor.separatorColor)
            static let primaryText = Color(NSColor.labelColor)
            static let secondaryText = Color(NSColor.secondaryLabelColor)
        }
    }

    // ============================================
    // 间距系统 - 4pt 网格
    // ============================================
    struct Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    // ============================================
    // 圆角系统
    // ============================================
    struct CornerRadius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let button: CGFloat = 6
        static let panel: CGFloat = 10
        static let preview: CGFloat = 6
        static let icon: CGFloat = 8
        static let windowItem: CGFloat = 10
    }

    // ============================================
    // 动画系统
    // ============================================
    struct Animation {
        static let panelShow = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.8)
        static let panelHide = SwiftUI.Animation.easeIn(duration: 0.15)
        static let itemHover = SwiftUI.Animation.easeOut(duration: 0.15)
        static let previewLoad = SwiftUI.Animation.easeOut(duration: 0.1)
        static let itemClose = SwiftUI.Animation.easeIn(duration: 0.2)

        // 改进：添加弹性动画 - 用于选中/悬停状态
        static func springery(response: Double, dampingFraction: Double) -> SwiftUI.Animation {
            SwiftUI.Animation.spring(response: response, dampingFraction: dampingFraction)
        }

        // 改进：添加平滑过渡动画 - 用于大预览区域
        static let previewTransition = SwiftUI.Animation.easeInOut(duration: 0.2)
    }

    // ============================================
    // 面板规格
    // ============================================
    struct Panel {
        static let width: CGFloat = 1100  // 减小宽度
        static let height: CGFloat = 550  // 减小高度
        static let padding: CGFloat = 12  // 减小内边距
        static let cornerRadius: CGFloat = 10
        static let shadowRadius: CGFloat = 20
        static let shadowY: CGFloat = 8
    }

    // ============================================
    // 窗口项规格
    // ============================================
    struct WindowItem {
        static let width: CGFloat = 130
        static let height: CGFloat = 130
        static let iconSize: CGFloat = 28
        static let iconCornerRadius: CGFloat = 6
        static let previewWidth: CGFloat = 114
        static let previewHeight: CGFloat = 64  // 16:9
        static let previewCornerRadius: CGFloat = 5
        static let spacing: CGFloat = 20  // 减小间距
        static let titleFontSize: CGFloat = 12
        static let subtitleFontSize: CGFloat = 10
    }

    // ============================================
    // 程序坞预览规格 (T-050 设计规范)
    // ============================================
    struct DockPreview {
        // 面板
        static let panelCornerRadius: CGFloat = 10
        static let shadowRadius: CGFloat = 12
        static let shadowY: CGFloat = 4

        // 预览项
        static let itemWidth: CGFloat = 120
        static let itemHeight: CGFloat = 80
        static let itemCornerRadius: CGFloat = 10

        // 预览图
        static let previewWidth: CGFloat = 104
        static let previewHeight: CGFloat = 58  // 16:9
        static let previewCornerRadius: CGFloat = 8

        // 字体
        static let titleFontSize: CGFloat = 11

        // 间距
        static let itemSpacing: CGFloat = 8

        // 动画
        static let showDelay: TimeInterval = 0.35  // 350ms 触发延迟
        static let showDuration: TimeInterval = 0.2  // 200ms 显示动画
        static let hideDuration: TimeInterval = 0.15  // 150ms 隐藏动画
    }

    // ============================================
    // 大预览区域规格 (Alt+Tab 切换预览)
    // ============================================
    struct LargePreview {
        static let width: CGFloat = 400
        static let height: CGFloat = 225  // 16:9
        static let cornerRadius: CGFloat = 8
        static let bottomPadding: CGFloat = 16
    }
}

// ============================================
// 字体层级系统
// ============================================

struct FontSystem {
    // 标题层级
    static let titleLarge = Font.system(size: 18, weight: .semibold)
    static let titleMedium = Font.system(size: 16, weight: .medium)
    static let titleSmall = Font.system(size: 14, weight: .medium)

    // 正文层级
    static let bodyLarge = Font.system(size: 14, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .regular)
    static let bodySmall = Font.system(size: 12, weight: .regular)

    // 辅助层级
    static let captionMedium = Font.system(size: 11, weight: .regular)
    static let captionSmall = Font.system(size: 10, weight: .regular)

    // 按钮字体
    static let button = Font.system(size: 13, weight: .medium)
    static let buttonSmall = Font.system(size: 11, weight: .medium)
}

// ============================================
// 响应式尺寸计算
// ============================================

struct ResponsiveSize {
    /// 根据屏幕尺寸计算设置窗口大小
    static func settingsWindowSize() -> CGSize {
        guard let screen = NSScreen.main else {
            return CGSize(width: 600, height: 580)
        }

        let screenWidth = screen.frame.width
        let screenHeight = screen.frame.height

        // 基准尺寸
        var width: CGFloat = 600
        var height: CGFloat = 580

        // 小屏幕适配
        if screenWidth < 1200 {
            width = min(550, screenWidth * 0.9)
            height = min(540, screenHeight * 0.8)
        } else if screenWidth > 1920 {
            // 大屏幕适配
            width = 680
            height = 640
        }

        return CGSize(width: width, height: height)
    }

    /// 计算窗口最小尺寸
    static let minWindowSize = CGSize(width: 480, height: 480)
}

// ============================================
// 设置界面分组枚举
// ============================================

enum SettingsGroup: String, CaseIterable {
    case general = "通用"
    case switcher = "切换器"
    case preview = "预览"
    case dock = "程序坞"
    case hotkey = "快捷键"
    case about = "关于"

    var icon: String {
        switch self {
        case .general: return "gearshape.2"
        case .switcher: return "rectangle.on.rectangle"
        case .preview: return "eye"
        case .dock: return "dock.rectangle"
        case .hotkey: return "keyboard"
        case .about: return "info.circle"
        }
    }

    var description: String {
        switch self {
        case .general: return "启动、主题等基础设置"
        case .switcher: return "窗口切换器行为配置"
        case .preview: return "预览窗口显示设置"
        case .dock: return "程序坞悬停预览设置"
        case .hotkey: return "快捷键自定义配置"
        case .about: return "版本信息与帮助"
        }
    }
}
