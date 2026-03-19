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
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
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
    }

    // ============================================
    // 面板规格
    // ============================================
    struct Panel {
        static let width: CGFloat = 720
        static let height: CGFloat = 480
        static let padding: CGFloat = 16
        static let cornerRadius: CGFloat = 10
        static let shadowRadius: CGFloat = 20
        static let shadowY: CGFloat = 8
    }

    // ============================================
    // 窗口项规格
    // ============================================
    struct WindowItem {
        static let width: CGFloat = 140
        static let height: CGFloat = 140
        static let iconSize: CGFloat = 32
        static let iconCornerRadius: CGFloat = 8
        static let previewWidth: CGFloat = 124
        static let previewHeight: CGFloat = 70  // 16:9
        static let previewCornerRadius: CGFloat = 6
        static let spacing: CGFloat = 12
        static let titleFontSize: CGFloat = 13
        static let subtitleFontSize: CGFloat = 11
    }
}
