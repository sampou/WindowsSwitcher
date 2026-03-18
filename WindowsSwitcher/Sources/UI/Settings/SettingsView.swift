import SwiftUI

/// T-045 完善设置界面：外观 / 行为 / 快捷键三个 Tab
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("外观", systemImage: "paintbrush") }

            BehaviorSettingsView()
                .tabItem { Label("行为", systemImage: "gearshape") }

            HotKeySettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 380)
        .padding()
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

            Section("面板") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack {
                        Text("透明度")
                        Spacer()
                        Text("\(Int(config.config.appearance.panelOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $config.config.appearance.panelOpacity, in: 0.5...1.0, step: 0.05)
                        .tint(DesignTokens.Colors.accent)
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack {
                        Text("圆角半径")
                        Spacer()
                        Text("\(Int(config.config.appearance.panelCornerRadius)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $config.config.appearance.panelCornerRadius, in: 4...24, step: 2)
                        .tint(DesignTokens.Colors.accent)
                }
            }

            Section("预览尺寸") {
                LabeledContent("宽度") {
                    Text("\(Int(config.config.appearance.previewWidth)) px")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("高度") {
                    Text("\(Int(config.config.appearance.previewHeight)) px")
                        .foregroundStyle(.secondary)
                }
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
            Section("窗口过滤") {
                Toggle("显示最小化窗口", isOn: $config.config.behavior.showMinimizedWindows)
                Toggle("显示隐藏窗口", isOn: $config.config.behavior.showHiddenWindows)
            }

            Section("排序") {
                Picker("排序方式", selection: $config.config.behavior.sortOrder) {
                    Text("最近使用").tag(SortOrder.recent)
                    Text("应用名称").tag(SortOrder.appName)
                    Text("窗口标题").tag(SortOrder.windowTitle)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("延迟") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack {
                        Text("面板显示延迟")
                        Spacer()
                        Text(String(format: "%.0f ms", config.config.behavior.panelDisplayDelay * 1000))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $config.config.behavior.panelDisplayDelay, in: 0...0.5, step: 0.05)
                        .tint(DesignTokens.Colors.accent)
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
                LabeledContent("显示切换器", value: "⌘ Tab")
                LabeledContent("反向切换", value: "⌘ ⇧ Tab")
                LabeledContent("应用内切换", value: "⌘ `")
            }

            Section {
                HStack {
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
