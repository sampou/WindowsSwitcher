import SwiftUI

/// T-044 搜索栏组件：实时过滤
struct SearchBarView: View {
    static var defaultPlaceholder: String { L10n.text("搜索应用、窗口或 Bundle ID...") }
    static var searchAccessibilityLabel: String { L10n.text("搜索窗口") }
    static var searchAccessibilityHint: String { L10n.text("输入应用名称、窗口标题或 Bundle Identifier 搜索") }

    @Binding var text: String
    var placeholder: String = SearchBarView.defaultPlaceholder
    var requestsFocusOnAppear = false

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
                .accessibilityLabel(SearchBarView.searchAccessibilityLabel)
                .accessibilityHint(SearchBarView.searchAccessibilityHint)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("清除搜索内容"))
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
        .onAppear {
            guard requestsFocusOnAppear else { return }
            // 等待 NSHostingView 完成首轮挂载后再请求焦点，避免请求被面板建窗过程覆盖。
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }
}
