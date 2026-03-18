import SwiftUI
import AppKit

/// T-043 预览视图组件：带加载状态和渐入动画
struct PreviewView: View {
    let window: WindowModel?
    let image: NSImage?
    let isLoading: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md)
                .fill(Color.black.opacity(0.15))

            if isLoading {
                loadingState
            } else if let image {
                imageState(image)
            } else {
                emptyState
            }

            if let window {
                titleOverlay(window)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }

    // MARK: - 加载中
    private var loadingState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .scaleEffect(1.2)
            Text("加载预览...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 图片渐入
    private func imageState(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
            .transition(.opacity.animation(DesignTokens.Animation.previewLoad))
    }

    // MARK: - 空状态
    private var emptyState: some View {
        Image(systemName: "rectangle.on.rectangle")
            .font(.system(size: 48))
            .foregroundStyle(.secondary)
    }

    // MARK: - 标题覆盖层
    private func titleOverlay(_ w: WindowModel) -> some View {
        VStack {
            Spacer()
            HStack {
                Image(nsImage: w.appIcon)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(w.windowTitle.isEmpty ? w.appName : w.windowTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.sm))
            .padding(.bottom, DesignTokens.Spacing.sm)
        }
    }
}
