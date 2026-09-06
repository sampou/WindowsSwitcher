import SwiftUI
import AppKit

/// T-046 菜单栏视图组件
struct MenuBarView: View {
    @ObservedObject private var config = ConfigManager.shared
    let onShowSwitcher: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题区
            HStack {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(DesignTokens.Colors.accent)
                Text("Window Switcher")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            menuItem(icon: "rectangle.on.rectangle", title: "显示切换器", shortcut: "⌥ Tab") {
                onShowSwitcher()
            }

            menuItem(icon: "gearshape", title: "设置", shortcut: "⌘ ,") {
                onOpenSettings()
            }

            Divider()

            menuItem(icon: "power", title: "退出", shortcut: "⌘ Q") {
                onQuit()
            }
        }
        .frame(width: 220)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func menuItem(icon: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(L10n.text(title))
                    .font(.system(size: 13))
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
