import SwiftUI
import AppKit

struct SwitchPanelView: View {
    @ObservedObject var viewModel: SwitchPanelViewModel
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // 毛玻璃背景
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.lg))

            VStack(spacing: DesignTokens.Spacing.md) {
                // 大预览区
                previewArea

                // 窗口图标栏
                windowIconBar

                // 搜索栏
                searchBar
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .frame(width: 800, height: 480)
        .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 8)
        .onKeyPress(keys: [.tab]) { _ in
            viewModel.selectNext(); return .handled
        }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.return) { viewModel.activateSelected(); onDismiss(); return .handled }
    }

    // MARK: - 大预览区
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md)
                .fill(Color.black.opacity(0.15))

            if let window = viewModel.selectedWindow,
               let image = viewModel.previewImages[window.id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
                    .transition(.opacity.animation(DesignTokens.Animation.previewLoad))
            } else {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }

            // 窗口标题
            if let window = viewModel.selectedWindow {
                VStack {
                    Spacer()
                    HStack {
                        Image(nsImage: window.appIcon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(window.windowTitle.isEmpty ? window.appName : window.windowTitle)
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
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }

    // MARK: - 窗口图标栏
    private var windowIconBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(Array(viewModel.filteredWindows.enumerated()), id: \.element.id) { index, window in
                    WindowThumbnailItem(
                        window: window,
                        isSelected: index == viewModel.selectedIndex,
                        previewImage: viewModel.previewImages[window.id],
                        onSelect: { viewModel.selectedIndex = index },
                        onActivate: { viewModel.activateSelected(); onDismiss() },
                        onClose: { viewModel.closeWindow(window) }
                    )
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
        }
        .frame(height: 96)
    }

    // MARK: - 搜索栏
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索窗口...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
    }
}

// MARK: - 窗口缩略图项
struct WindowThumbnailItem: View {
    let window: WindowModel
    let isSelected: Bool
    let previewImage: NSImage?
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: DesignTokens.Spacing.xs) {
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
                    } else {
                        Image(nsImage: window.appIcon)
                            .resizable()
                            .frame(width: 32, height: 32)
                    }
                }
                .frame(width: 96, height: 72)

                Text(window.appName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? DesignTokens.Colors.accent : .primary)
            }

            // 关闭按钮（悬停时显示）
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .transition(.opacity)
            }
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(DesignTokens.Animation.itemHover, value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onActivate() }
        .onTapGesture(count: 1) { onSelect() }
    }
}

// MARK: - NSVisualEffectView 包装
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
