import SwiftUI
import AppKit

/// 版本更新提示窗口
struct UpdateNotificationView: View {
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var config = ConfigManager.shared
    let onDismiss: () -> Void
    let onStartDownload: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部渐变背景区域
            ZStack {
                LinearGradient(
                    colors: [Color.blue.opacity(0.08), Color.purple.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 16) {
                    // 应用图标
                    Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

                    // 标题
                    Text("发现新版本")
                        .font(.system(size: 26, weight: .bold))

                    // 版本号
                    if let latest = updateService.latestVersion {
                        HStack(spacing: 8) {
                            Text("v\(latest.version)")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.blue)

                            Text("现已发布")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 32)
            }
            .frame(height: 200)

            // 更新内容
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let latest = updateService.latestVersion {
                        // 当前版本提示
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            Text("当前版本 v\(updateService.currentVersion)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        Divider()

                        // 更新说明
                        Text("更新内容")
                            .font(.system(size: 15, weight: .semibold))

                        Text(latest.releaseNotes ?? "建议更新以获得最新功能。")
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("建议更新以获得最新功能。")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: 260)

            Divider()

            // 底部区域
            VStack(spacing: 16) {
                // 自动检查更新选项（仅当未开启时显示）
                if !config.config.update.autoCheckEnabled {
                    HStack {
                        Toggle(isOn: $config.config.update.autoCheckEnabled) {
                            Text("自动检查更新")
                                .font(.system(size: 13))
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
                    .onChange(of: config.config.update.autoCheckEnabled) { newValue in
                        if newValue {
                            updateService.startAutoCheck()
                        }
                    }
                }

                // 按钮
                HStack(spacing: 16) {
                    Button(action: { onDismiss() }) {
                        Text("稍后提醒")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape)

                    Button(action: {
                        onStartDownload()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("立即下载")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// 版本更新窗口控制器
class UpdateNotificationWindowController: NSWindowController, NSWindowDelegate {
    private var hostingView: NSHostingView<UpdateNotificationView>?
    private var downloadWindowController: UpdateDownloadWindowController?
    private var onDismissHandler: (() -> Void)?

    convenience init(onDismiss: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "软件更新"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        self.onDismissHandler = onDismiss
        window.delegate = self

        let view = UpdateNotificationView(
            onDismiss: { [weak self] in
                self?.closeWindow()
            },
            onStartDownload: { [weak self] in
                self?.showDownloadWindow()
            }
        )
        hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        close()
        onDismissHandler?()
    }

    private func showDownloadWindow() {
        close()

        downloadWindowController = UpdateDownloadWindowController { [weak self] in
            self?.downloadWindowController?.close()
            self?.downloadWindowController = nil
            self?.onDismissHandler?()
        }
        downloadWindowController?.show()
    }

    func windowWillClose(_ notification: Notification) {
        onDismissHandler?()
    }
}
