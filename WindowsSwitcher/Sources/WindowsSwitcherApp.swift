import SwiftUI

@main
struct WindowsSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 菜单栏应用不创建主窗口；设置仍由 AppDelegate 管理。
        // Settings 场景保持 SwiftUI 生命周期，避免 WindowGroup 生成无法匹配关闭的空窗。
        Settings { EmptyView() }
        .commands {
            // 替换默认的设置菜单项，使用 AppDelegate.openSettings
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("设置...")) {
                    NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
