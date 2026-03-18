import SwiftUI

@main
struct WindowsSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 菜单栏应用：只有设置窗口，主界面通过快捷键触发
        Settings {
            SettingsView()
        }
    }
}
