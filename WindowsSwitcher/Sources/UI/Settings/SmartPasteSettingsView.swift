import SwiftUI
import AppKit

/// 智能目录粘贴设置。
struct SmartPasteSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @ObservedObject private var permissionManager = PermissionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            SettingsSection(title: "智能目录粘贴", icon: "folder.badge.gearshape") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    SettingsToggle(
                        title: L10n.text("启用智能目录粘贴"),
                        description: "复制目录路径后，在文件选择窗口中按 ⌘V 即可跳转到该目录",
                        isOn: $config.config.smartPaste.enabled
                    )

                    Divider()

                    permissionStatus

                    Divider()

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text(L10n.text("使用说明"))
                            .font(FontSystem.bodyMedium)

                        instructionRow(1, L10n.text("在 Finder 中复制一个目录（⌘C）。"))
                        instructionRow(2, L10n.text("打开任意应用的文件选择窗口。"))
                        instructionRow(3, L10n.text("让焦点停在文件列表上，按 ⌘V 即可跳转到该目录。"))

                        Text(L10n.text("光标位于文件名输入框或搜索框时，⌘V 仍按原生方式粘贴路径文本，不会跳转目录。"))
                            .font(FontSystem.captionMedium)
                            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            .padding(.top, DesignTokens.Spacing.xs)
                    }
                }
            }

            SettingsSection(title: "高级设置", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    timeoutRow

                    SettingsToggle(
                        title: L10n.text("失败时显示提示"),
                        description: "跳转失败时在屏幕角落显示非模态提示",
                        isOn: $config.config.smartPaste.showFailureToast
                    )

                    SettingsToggle(
                        title: L10n.text("在日志中记录目录路径"),
                        description: "默认关闭：目录路径可能包含用户名或项目名",
                        isOn: $config.config.smartPaste.logDirectoryPaths
                    )

                    SettingsToggle(
                        title: L10n.text("启用右键跳转"),
                        description: "在文件面板中右键，直接跳转到剪贴板中的目录",
                        isOn: $config.config.smartPaste.rightClickJumpEnabled
                    )

                    SettingsToggle(
                        title: L10n.text("右键跳转时抑制系统菜单"),
                        description: "开启后该次右键不弹出系统原生菜单，避免合成按键被菜单吞掉",
                        isOn: $config.config.smartPaste.suppressSystemContextMenu
                    )
                }
            }
        }
    }

    /// 导航超时：需要保留一位小数，因此不使用通用滑块组件。
    private var timeoutRow: some View {
        HStack {
            Text(L10n.text("导航超时"))
                .font(FontSystem.bodyMedium)

            Spacer()

            Text(String(format: "%.1f %@",
                        config.config.smartPaste.navigationTimeout,
                        L10n.text("秒")))
                .font(FontSystem.bodySmall)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                .monospacedDigit()

            Stepper("",
                    value: $config.config.smartPaste.navigationTimeout,
                    in: 0.5...3.0,
                    step: 0.1)
                .labelsHidden()
        }
    }

    // MARK: - 权限状态

    @ViewBuilder
    private var permissionStatus: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: permissionManager.accessibilityStatus.isAuthorized
                      ? "checkmark.shield.fill"
                      : "exclamationmark.shield.fill")
                    .foregroundStyle(permissionManager.accessibilityStatus.isAuthorized ? .green : .orange)

                Text(L10n.text("辅助功能权限"))
                    .font(FontSystem.bodyMedium)

                Spacer()

                Text(permissionManager.accessibilityStatus.isAuthorized
                     ? L10n.text("已授权")
                     : L10n.text("未授权"))
                    .font(FontSystem.bodySmall)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            }

            if !permissionManager.accessibilityStatus.isAuthorized {
                HStack {
                    Text(L10n.text("智能目录粘贴依赖辅助功能权限，请为 WindowsSwitcher 授权后开启功能。"))
                        .font(FontSystem.captionMedium)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)

                    Spacer()

                    Button(L10n.text("请求授权")) {
                        permissionManager.requestAccessibilityPermission()
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
        }
    }

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text("\(number)")
                .font(FontSystem.captionSmall)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                .frame(width: 16, alignment: .center)

            Text(text)
                .font(FontSystem.captionMedium)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)

            Spacer(minLength: 0)
        }
    }
}
