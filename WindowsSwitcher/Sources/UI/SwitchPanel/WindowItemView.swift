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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                previewArea
                appInfo
            }
            .padding(DesignTokens.Spacing.xs)
            .frame(width: DesignTokens.WindowItem.width, height: DesignTokens.WindowItem.height)
            .background(itemBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.windowItem))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.windowItem)
                    .stroke(isSelected ? DesignTokens.Colors.accent : Color.clear, lineWidth: 2)
            )

            if isHovered { actionButtons }
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(DesignTokens.Animation.itemHover, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 1) {
            onSelect()
            onActivate()
        }
    }

    // MARK: - 预览图
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius)
                .fill(DesignTokens.Colors.secondaryBackground)

            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius))
                    .transition(.opacity.animation(DesignTokens.Animation.previewLoad))
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
        .frame(width: DesignTokens.WindowItem.previewWidth, height: DesignTokens.WindowItem.previewHeight)
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

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .red)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(.black.opacity(0.4))
        .clipShape(Capsule())
        .offset(x: -4, y: 4)
        .transition(.opacity.animation(DesignTokens.Animation.itemHover))
    }
}
