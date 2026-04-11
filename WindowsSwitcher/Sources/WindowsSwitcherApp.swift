import SwiftUI

@main
struct WindowsSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 菜单栏应用：只有设置窗口，主界面通过快捷键触发
        // SettingsView 内部已通过 @ObservedObject 监听 ThemeManager，自动响应主题变化
        Settings {
            SettingsView()
        }
    }
}
