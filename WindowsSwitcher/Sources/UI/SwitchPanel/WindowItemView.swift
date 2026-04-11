import SwiftUI
import AppKit

/// T-042 窗口项组件 - 新设计：预览图 + 应用图标 + 标题，网格布局
struct WindowItemView: View {
    let window: WindowModel
    let isSelected: Bool
    let previewImage: NSImage?
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void

    @State private var isHovered = false
    @ObservedObject private var configManager = ConfigManager.shared

    // 动态获取预览尺寸
    private var previewSize: PreviewSize {
        configManager.config.appearance.previewSize
    }
    private var itemWidth: CGFloat {
        previewSize.itemDimensions.width
    }

    private var itemHeight: CGFloat {
        previewSize.itemDimensions.height
    }

    private var previewWidth: CGFloat {
        previewSize.dimensions.width
    }

    private var previewHeight: CGFloat {
        previewSize.dimensions.height
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                previewArea
                appInfo
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(width: itemWidth, height: itemHeight)
            .background(itemBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.windowItem))
            // 移除所有动画以提升性能
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.windowItem)
                    .stroke(isSelected ? DesignTokens.Colors.accent : Color.clear, lineWidth: 2)
            )
            .padding(8)
            // 禁用 hover 动画
            .animation(.none, value: isHovered)

            if isHovered { actionButtons }
        }
        .onHover { isHovered = $0 }
        .onTapGesture(count: 1) {
            onSelect()
            onActivate()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.appName)，\(window.windowTitle)\(isSelected ? "，已选中" : "")")
        .accessibilityHint("双击切换到该窗口")
    }

    // MARK: - 预览图
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius)
                .fill(DesignTokens.Colors.secondaryBackground)

            if let image = previewImage {
                // 根据实际窗口比例显示
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius))
            } else {
                Image(nsImage: window.appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .opacity(0.4)
            }

            if window.isMinimized || window.isHidden {
                VStack {
                    Spacer()
                    HStack {
                        Label(
                            window.isMinimized ? "已最小化" : "已隐藏",
                            systemImage: window.isMinimized ? "minus.circle.fill" : "eye.slash.fill"
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(4)
                        Spacer()
                    }
                }
            }
        }
        // 使用实际窗口比例显示
        .aspectRatio(windowAspectRatio, contentMode: .fit)
        .frame(maxWidth: previewWidth, maxHeight: previewHeight)
        .frame(minWidth: 60, minHeight: 40)
    }

    // 计算实际窗口的宽高比
    private var windowAspectRatio: CGFloat {
        let width = window.frame.width
        let height = window.frame.height
        guard width > 0 && height > 0 else { return 16.0 / 9.0 }
        return width / height
    }

    // MARK: - 应用信息
    private var appInfo: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(nsImage: window.appIcon)
                .resizable()
                .frame(width: DesignTokens.WindowItem.iconSize, height: DesignTokens.WindowItem.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.WindowItem.iconCornerRadius))

            VStack(alignment: .leading, spacing: 1) {
                Text(window.appName)
                    .font(.system(size: DesignTokens.WindowItem.titleFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.label)
                    .lineLimit(1)

                if !window.windowTitle.isEmpty && window.windowTitle != window.appName {
                    Text(window.windowTitle)
                        .font(.system(size: DesignTokens.WindowItem.subtitleFontSize))
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
    }

    // MARK: - 背景
    @ViewBuilder
    private var itemBackground: some View {
        if isSelected {
            DesignTokens.Colors.selectedControl.opacity(0.3)
        } else if isHovered {
            DesignTokens.Colors.secondaryBackground.opacity(0.6)
        } else {
            Color.clear
        }
    }

    // MARK: - 操作按钮
    private var actionButtons: some View {
        HStack(spacing: 2) {
            Button(action: onMinimize) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.white, .orange)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("最小化窗口")
            .accessibilityHint("将窗口最小化到程序坞")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .red)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭窗口")
            .accessibilityHint("关闭当前窗口")
        }
        .padding(4)
        .background(.black.opacity(0.4))
        .clipShape(Capsule())
        .offset(x: -4, y: 4)
        .transition(.opacity.animation(DesignTokens.Animation.itemHover))
    }
}
