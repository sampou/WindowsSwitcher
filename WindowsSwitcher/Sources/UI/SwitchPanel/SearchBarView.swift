import SwiftUI

/// T-044 搜索栏组件：实时过滤
struct SearchBarView: View {
    @Binding var text: String
    var placeholder: String = "搜索窗口..."

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .accessibilityLabel("搜索窗口")
                .accessibilityHint("输入应用名称或窗口标题搜索")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索内容")
                .transition(.opacity.animation(DesignTokens.Animation.itemHover))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.Colors.secondaryBackground.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.button))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.button)
                .stroke(isFocused ? DesignTokens.Colors.accent.opacity(0.6) : DesignTokens.Colors.separator, lineWidth: 1)
        )
        .animation(DesignTokens.Animation.itemHover, value: isFocused)
    }
}
