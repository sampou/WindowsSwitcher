import SwiftUI

@main
struct WindowsSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 菜单栏应用：设置窗口通过 AppDelegate.openSettings() 打开
        // 使用 WindowGroup 但隐藏主窗口
        WindowGroup {
            EmptyView()
                .onAppear {
                    // 关闭自动显示的空窗口
                    if let window = NSApplication.shared.windows.first(where: { $0.contentView?.subviews.first is NSHostingView<EmptyView> }) {
                        window.close()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1, height: 1)
        .commands {
            // 替换默认的设置菜单项，使用 AppDelegate.openSettings
            CommandGroup(replacing: .appSettings) {
                Button("设置...") {
                    NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
