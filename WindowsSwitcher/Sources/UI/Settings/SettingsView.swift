import SwiftUI

/// F07 设置面板：外观 / 行为 / 快捷键，含保存失败提示和重置功能
struct SettingsView: View {
    @ObservedObject private var config = ConfigManager.shared
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // 保存失败横幅
            if let error = config.saveError {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        config.saveError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(Color.yellow.opacity(0.15))
            }

            TabView {
                AppearanceSettingsView()
                    .tabItem { Label("外观", systemImage: "paintbrush") }

                BehaviorSettingsView()
                    .tabItem { Label("行为", systemImage: "gearshape") }

                HotKeySettingsView()
                    .tabItem { Label("快捷键", systemImage: "keyboard") }
            }

            // 底部重置按钮
            Divider()
            HStack {
                Spacer()
                Button("恢复默认设置") {
                    showResetConfirm = true
                }
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
        }
        .frame(width: 480, height: 420)
        .confirmationDialog("确认恢复默认设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { config.reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有设置将恢复为出厂默认值，此操作不可撤销。")
        }
    }
}

// MARK: - 外观

struct AppearanceSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        Form {
            Section("主题") {
                Picker("主题模式", selection: $config.config.appearance.theme) {
                    Text("浅色").tag(AppTheme.light)
                    Text("深色").tag(AppTheme.dark)
                    Text("跟随系统").tag(AppTheme.auto)
                }
                .pickerStyle(.segmented)
            }

            Section("预览窗口") {
                Picker("预览大小", selection: $config.config.appearance.previewSize) {
                    Text("小").tag(PreviewSize.small)
                    Text("中").tag(PreviewSize.medium)
                    Text("大").tag(PreviewSize.large)
                }
                .pickerStyle(.segmented)

                Picker("每行列数", selection: $config.config.appearance.switcherColumns) {
                    Text("自动").tag(0)
                    Text("3列").tag(3)
                    Text("4列").tag(4)
                    Text("5列").tag(5)
                    Text("6列").tag(6)
                    Text("8列").tag(8)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

// MARK: - 行为

struct BehaviorSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        Form {
            Section("窗口显示") {
                Toggle("显示最小化窗口", isOn: $config.config.behavior.showMinimizedWindows)
                Toggle("显示隐藏窗口", isOn: $config.config.behavior.showHiddenWindows)
                Toggle("默认选中第二个窗口", isOn: $config.config.behavior.defaultSelectSecond)
            }

            Section("切换器背景预览") {
                Toggle("显示背景预览", isOn: $config.config.behavior.showBackgroundPreview)
            }

            Section("程序坞预览") {
                Toggle("启用程序坞预览", isOn: $config.config.dockPreview.enabled)

                if config.config.dockPreview.enabled {
                    // 悬停延迟
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text("悬停延迟")
                            Spacer()
                            Text(String(format: "%.0f ms", config.config.dockPreview.hoverDelay * 1000))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $config.config.dockPreview.hoverDelay, in: 0.05...0.5, step: 0.05)
                            .tint(DesignTokens.Colors.accent)
                    }

                    // 隐藏延迟
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text("隐藏延迟")
                            Spacer()
                            Text(String(format: "%.0f ms", config.config.dockPreview.hideDelay * 1000))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $config.config.dockPreview.hideDelay, in: 0.05...0.5, step: 0.05)
                            .tint(DesignTokens.Colors.accent)
                    }

                    // 最大预览数量
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text("最大预览数量")
                            Spacer()
                            Text("\(config.config.dockPreview.maxPreviewCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(config.config.dockPreview.maxPreviewCount) },
                            set: { config.config.dockPreview.maxPreviewCount = Int($0) }
                        ), in: 2...8, step: 1)
                        .tint(DesignTokens.Colors.accent)
                    }

                    // 显示动画
                    Toggle("显示动画效果", isOn: $config.config.dockPreview.showAnimation)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

// MARK: - 快捷键

struct HotKeySettingsView: View {
    var body: some View {
        Form {
            Section("当前快捷键") {
                LabeledContent("显示切换器", value: "⌥ Tab")
                LabeledContent("反向切换", value: "⌥ ⇧ Tab")
                LabeledContent("应用内切换", value: "⌥ `")
            }

            Section {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DesignTokens.Colors.accent)
                    Text("快捷键自定义功能将在 v1.1 中开放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}
