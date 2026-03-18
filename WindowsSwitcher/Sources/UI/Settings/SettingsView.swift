import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("外观", systemImage: "paintbrush") }

            BehaviorSettingsView()
                .tabItem { Label("行为", systemImage: "gearshape") }

            HotKeySettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 360)
        .padding()
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        Form {
            Picker("主题", selection: $config.config.appearance.theme) {
                Text("浅色").tag(AppTheme.light)
                Text("深色").tag(AppTheme.dark)
                Text("跟随系统").tag(AppTheme.auto)
            }
            Slider(value: $config.config.appearance.panelOpacity, in: 0.5...1.0) {
                Text("面板透明度")
            }
            Slider(value: $config.config.appearance.panelCornerRadius, in: 4...24) {
                Text("圆角半径")
            }
        }
        .padding()
    }
}

struct BehaviorSettingsView: View {
    @ObservedObject private var config = ConfigManager.shared

    var body: some View {
        Form {
            Picker("排序方式", selection: $config.config.behavior.sortOrder) {
                Text("最近使用").tag(SortOrder.recent)
                Text("应用名称").tag(SortOrder.appName)
                Text("窗口标题").tag(SortOrder.windowTitle)
            }
            Toggle("显示最小化窗口", isOn: $config.config.behavior.showMinimizedWindows)
            Toggle("显示隐藏窗口", isOn: $config.config.behavior.showHiddenWindows)
        }
        .padding()
    }
}

struct HotKeySettingsView: View {
    var body: some View {
        Form {
            LabeledContent("窗口切换", value: "⌘ Tab")
            LabeledContent("反向切换", value: "⌘ ⇧ Tab")
            LabeledContent("应用内切换", value: "⌘ `")
            Text("快捷键自定义功能将在 v1.1 中开放")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
