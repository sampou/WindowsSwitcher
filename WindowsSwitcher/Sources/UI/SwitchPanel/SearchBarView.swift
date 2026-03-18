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

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .transition(.opacity.animation(DesignTokens.Animation.itemHover))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.md)
                .stroke(isFocused ? DesignTokens.Colors.accent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .animation(DesignTokens.Animation.itemHover, value: isFocused)
    }
}
