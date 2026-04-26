import SwiftUI
import AppKit

/// 下载进度视图
struct UpdateDownloadView: View {
    @ObservedObject private var downloadManager = UpdateDownloadManager.shared
    @ObservedObject private var updateService = UpdateService.shared
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部区域
            VStack(spacing: 16) {
                // 应用图标
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)

                Text("正在下载更新")
                    .font(.system(size: 18, weight: .semibold))

                if let version = updateService.latestVersion?.version {
                    Text("v\(version)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()
                .padding(.horizontal, 24)

            // 下载进度区域
            VStack(spacing: 16) {
                // 状态文本
                Text(downloadManager.statusMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // 进度条
                VStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 8)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue)
                                .frame(width: geometry.size.width * downloadManager.progress, height: 8)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text("\(Int(downloadManager.progress * 100))%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.blue)

                        Spacer()

                        if downloadManager.downloadSpeed > 0 {
                            Text(downloadManager.formattedSpeed)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 文件大小信息
                if downloadManager.totalBytes > 0 {
                    HStack {
                        Text("\(downloadManager.formattedDownloaded) / \(downloadManager.formattedTotal)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(24)

            Divider()
                .padding(.horizontal, 24)

            // 底部按钮
            HStack(spacing: 16) {
                if downloadManager.isDownloading {
                    Button("取消下载") {
                        downloadManager.cancelDownload()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                } else if downloadManager.isPaused {
                    Button("继续下载") {
                        downloadManager.resumeDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("取消") {
                        downloadManager.cancelDownload()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                } else if downloadManager.isCompleted {
                    Button("安装更新") {
                        downloadManager.installUpdate()
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("稍后安装") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                } else if downloadManager.hasError {
                    Button("重试") {
                        downloadManager.startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("取消") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                } else {
                    Button("开始下载") {
                        downloadManager.startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("稍后提醒") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if !downloadManager.isDownloading && !downloadManager.isCompleted {
                downloadManager.startDownload()
            }
        }
    }
}

/// 下载窗口控制器
class UpdateDownloadWindowController: NSWindowController, NSWindowDelegate {
    private var hostingView: NSHostingView<UpdateDownloadView>?
    private var onDismissHandler: (() -> Void)?
    private var isClosing = false

    convenience init(onDismiss: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "下载更新"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        self.onDismissHandler = onDismiss
        window.delegate = self

        let view = UpdateDownloadView(onDismiss: { [weak self] in
            self?.closeWindow()
        })
        hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        guard !isClosing else { return }
        isClosing = true
        window?.close()
        onDismissHandler?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        if UpdateDownloadManager.shared.isDownloading {
            UpdateDownloadManager.shared.pauseDownload()
        }
        onDismissHandler?()
    }
}

/// 下载管理器
class UpdateDownloadManager: NSObject, ObservableObject {
    static let shared = UpdateDownloadManager()

    @Published var progress: Double = 0
    @Published var statusMessage: String = "准备下载..."
    @Published var downloadSpeed: Int64 = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var isDownloading: Bool = false
    @Published var isPaused: Bool = false
    @Published var isCompleted: Bool = false
    @Published var hasError: Bool = false
    @Published var errorMessage: String?

    private var downloadTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var session: URLSession!
    private var localFileURL: URL?

    private var speedTimer: Timer?
    private var previousBytes: Int64 = 0

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - 格式化显示

    var formattedSpeed: String {
        ByteCountFormatter.string(fromByteCount: downloadSpeed, countStyle: .file) + "/s"
    }

    var formattedDownloaded: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    // MARK: - 下载操作

    /// 开始下载
    func startDownload() {
        guard let versionInfo = UpdateService.shared.latestVersion else {
            Logger.operation("下载更新", detail: "没有版本信息", result: "失败")
            errorMessage = "没有可用的更新"
            hasError = true
            return
        }

        guard let url = URL(string: versionInfo.downloadURL) else {
            Logger.operation("下载更新", detail: "下载地址无效", result: "失败")
            errorMessage = "下载地址无效"
            hasError = true
            return
        }

        Logger.operation("下载更新", detail: "开始下载: \(url.absoluteString)")
        resetState()
        isDownloading = true
        statusMessage = "正在连接服务器..."

        if let resumeData = resumeData {
            downloadTask = session.downloadTask(withResumeData: resumeData)
            Logger.operation("下载更新", detail: "使用断点续传")
        } else {
            downloadTask = session.downloadTask(with: url)
        }

        downloadTask?.resume()
        startSpeedCalculator()
    }

    /// 暂停下载
    func pauseDownload() {
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            DispatchQueue.main.async {
                self?.resumeData = data
                self?.isPaused = true
                self?.isDownloading = false
                self?.statusMessage = "下载已暂停"
                self?.stopSpeedCalculator()
                Logger.operation("下载更新", detail: "暂停下载，已保存断点")
            }
        })
    }

    /// 继续下载
    func resumeDownload() {
        guard resumeData != nil else {
            startDownload()
            return
        }

        Logger.operation("下载更新", detail: "继续下载")
        resetState()
        isDownloading = true
        statusMessage = "继续下载..."

        downloadTask = session.downloadTask(withResumeData: resumeData!)
        downloadTask?.resume()
        startSpeedCalculator()
    }

    /// 取消下载
    func cancelDownload() {
        downloadTask?.cancel()
        resumeData = nil
        stopSpeedCalculator()
        resetState()
        cleanupTempFile()
        Logger.operation("下载更新", detail: "取消下载")
    }

    /// 安装更新
    func installUpdate() {
        guard let fileURL = localFileURL else {
            Logger.operation("安装更新", detail: "没有下载文件", result: "失败")
            return
        }

        Logger.operation("安装更新", detail: "打开文件: \(fileURL.path)")
        NSWorkspace.shared.open(fileURL)

        // 延迟删除临时文件
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.cleanupTempFile()
        }
    }

    // MARK: - 私有方法

    private func resetState() {
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        downloadSpeed = 0
        isDownloading = false
        isPaused = false
        isCompleted = false
        hasError = false
        errorMessage = nil
    }

    private func startSpeedCalculator() {
        previousBytes = downloadedBytes
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentBytes = self.downloadedBytes
            self.downloadSpeed = currentBytes - self.previousBytes
            self.previousBytes = currentBytes
        }
    }

    private func stopSpeedCalculator() {
        speedTimer?.invalidate()
        speedTimer = nil
        downloadSpeed = 0
    }

    private func cleanupTempFile() {
        guard let url = localFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        localFileURL = nil
        Logger.operation("清理临时文件", detail: url.path)
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateDownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        stopSpeedCalculator()

        // 移动到临时目录
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "WindowsSwitcher_Update.dmg"
        let destinationURL = tempDir.appendingPathComponent(fileName)

        do {
            // 如果目标文件存在，先删除
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: location, to: destinationURL)
            localFileURL = destinationURL

            DispatchQueue.main.async {
                self.isDownloading = false
                self.isCompleted = true
                self.progress = 1.0
                self.statusMessage = "下载完成"
                Logger.operation("下载更新", detail: "下载完成: \(destinationURL.path)", result: "成功")
            }
        } catch {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.hasError = true
                self.errorMessage = "保存文件失败: \(error.localizedDescription)"
                Logger.operation("下载更新", detail: "保存失败: \(error.localizedDescription)", result: "失败")
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite

            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }

            let downloaded = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
            self.statusMessage = "已下载 \(downloaded)"
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        DispatchQueue.main.async {
            self.downloadedBytes = fileOffset
            self.totalBytes = expectedTotalBytes
            Logger.operation("下载更新", detail: "断点续传从 \(fileOffset) 字节开始")
        }
    }
}

// MARK: - URLSessionTaskDelegate

extension UpdateDownloadManager: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }

        stopSpeedCalculator()

        // 检查是否可以恢复
        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            self.resumeData = resumeData
            DispatchQueue.main.async {
                self.isDownloading = false
                self.isPaused = true
                self.statusMessage = "下载中断，可继续"
                Logger.operation("下载更新", detail: "下载中断，已保存断点")
            }
        } else {
            DispatchQueue.main.async {
                self.isDownloading = false
                self.hasError = true
                self.errorMessage = "下载失败: \(error.localizedDescription)"
                Logger.operation("下载更新", detail: "下载失败: \(error.localizedDescription)", result: "失败")
            }
        }
    }
}
