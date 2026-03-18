import SwiftUI
import AppKit

/// T-042 独立窗口项组件：应用图标 + 标题 + 预览缩略图 + 操作按钮
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
            VStack(spacing: DesignTokens.Spacing.xs) {
                thumbnailArea
                appLabel
            }

            if isHovered {
                actionButtons
            }
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(DesignTokens.Animation.itemHover, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onActivate() }
        .onTapGesture(count: 1) { onSelect() }
    }

    // MARK: - 缩略图区域
    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm)
                .fill(isSelected ? DesignTokens.Colors.accentLight : Color.secondary.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm)
                        .stroke(isSelected ? DesignTokens.Colors.accent : Color.clear, lineWidth: 2)
                )

            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm))
                    .transition(.opacity.animation(DesignTokens.Animation.previewLoad))
            } else {
                Image(nsImage: window.appIcon)
                    .resizable()
                    .frame(width: 32, height: 32)
            }

            // 最小化/隐藏状态标记
            if window.isMinimized || window.isHidden {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: window.isMinimized ? "minus.circle.fill" : "eye.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .padding(DesignTokens.Spacing.xs)
                        Spacer()
                    }
                }
            }
        }
        .frame(width: 96, height: 72)
    }

    // MARK: - 应用名标签
    private var appLabel: some View {
        Text(window.appName)
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(isSelected ? DesignTokens.Colors.accent : .primary)
    }

    // MARK: - 操作按钮（悬停时显示）
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
        .offset(x: 4, y: -4)
        .transition(.opacity)
    }
}
