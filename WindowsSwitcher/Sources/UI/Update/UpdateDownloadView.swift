import SwiftUI
import AppKit

// MARK: - 安装状态枚举

/// 安装状态
enum InstallState: Equatable {
    case idle
    case preparing
    case backingUp
    case mounting
    case verifying
    case installing(progress: Double)
    case completed
    case failed(error: String)
    case rollback

    var message: String {
        switch self {
        case .idle:
            return "准备安装"
        case .preparing:
            return "准备中..."
        case .backingUp:
            return "备份当前版本..."
        case .mounting:
            return "挂载安装包..."
        case .verifying:
            return "验证应用签名..."
        case .installing(let progress):
            return "正在安装... \(Int(progress * 100))%"
        case .completed:
            return "安装完成"
        case .failed(let error):
            return "安装失败: \(error)"
        case .rollback:
            return "正在回滚..."
        }
    }
}

// MARK: - 安装错误枚举

/// 安装错误
enum InstallError: Error, LocalizedError {
    case dmgNotFound
    case mountFailed(String)
    case signatureInvalid(String)
    case permissionDenied
    case installFailed(String)
    case backupFailed(String)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .dmgNotFound:
            return "安装包不存在"
        case .mountFailed(let message):
            return "挂载失败: \(message)"
        case .signatureInvalid(let message):
            return "签名验证失败: \(message)"
        case .permissionDenied:
            return "权限被拒绝"
        case .installFailed(let message):
            return "安装失败: \(message)"
        case .backupFailed(let message):
            return "备份失败: \(message)"
        case .rollbackFailed(let message):
            return "回滚失败: \(message)"
        }
    }
}

// MARK: - 静默安装器

/// 静默安装器
class SilentInstaller: ObservableObject {
    static let shared = SilentInstaller()

    @Published var state: InstallState = .idle
    @Published var progress: Double = 0

    private var backupPath: URL?
    private var mountPoint: String?

    private init() {}

    /// 执行静默安装
    /// - Parameters:
    ///   - fileURL: DMG 文件路径
    ///   - completion: 完成回调
    func install(from fileURL: URL, completion: @escaping (Result<Void, InstallError>) -> Void) {
        // 重置状态
        DispatchQueue.main.async {
            self.state = .preparing
            self.progress = 0
        }

        Logger.operation("静默安装", detail: "开始安装: \(fileURL.path)")

        // 在后台线程执行
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Step 1: 前置检查
                try self.preCheck(dmgPath: fileURL)

                // Step 2: 备份当前版本
                try self.backupCurrentVersion()

                // Step 3: 挂载 DMG
                let appPath = try self.mountDMG(dmgPath: fileURL)

                // Step 4: 验证签名
                try self.verifySignature(appPath: URL(fileURLWithPath: appPath))

                // Step 5: 安装应用
                try self.installApp(from: appPath)

                // Step 6: 完成
                DispatchQueue.main.async {
                    self.state = .completed
                    Logger.operation("静默安装", detail: "安装完成", result: "成功")
                    completion(.success(()))
                }

            } catch let error as InstallError {
                // 安装失败，尝试回滚
                self.handleFailure(error: error, completion: completion)
            } catch {
                // 其他错误
                let installError = InstallError.installFailed(error.localizedDescription)
                self.handleFailure(error: installError, completion: completion)
            }
        }
    }

    // MARK: - 私有方法

    /// 前置检查
    private func preCheck(dmgPath: URL) throws {
        DispatchQueue.main.async {
            self.state = .preparing
        }

        Logger.operation("静默安装", detail: "前置检查")

        // 检查 DMG 文件是否存在
        guard FileManager.default.fileExists(atPath: dmgPath.path) else {
            throw InstallError.dmgNotFound
        }

        // 检查磁盘空间（至少 500MB）
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: "/"),
           let freeSize = attributes[.systemFreeSize] as? Int64 {
            let requiredSpace: Int64 = 500 * 1024 * 1024 // 500MB
            if freeSize < requiredSpace {
                throw InstallError.installFailed("磁盘空间不足，至少需要 500MB")
            }
        }
    }

    /// 备份当前版本
    private func backupCurrentVersion() throws {
        DispatchQueue.main.async {
            self.state = .backingUp
        }

        Logger.operation("静默安装", detail: "备份当前版本")

        do {
            backupPath = try Self.backupApp()
        } catch {
            throw InstallError.backupFailed(error.localizedDescription)
        }
    }

    /// 挂载 DMG
    private func mountDMG(dmgPath: URL) throws -> String {
        DispatchQueue.main.async {
            self.state = .mounting
        }

        Logger.operation("静默安装", detail: "挂载 DMG")

        do {
            let result = try Self.mountDMGFile(dmgPath: dmgPath)
            mountPoint = result.mountPoint
            return result.appPath
        } catch {
            throw InstallError.mountFailed(error.localizedDescription)
        }
    }

    /// 验证签名
    private func verifySignature(appPath: URL) throws {
        DispatchQueue.main.async {
            self.state = .verifying
        }

        Logger.operation("静默安装", detail: "验证签名")

        do {
            try Self.verifyCodeSign(appPath: appPath)
        } catch {
            throw InstallError.signatureInvalid(error.localizedDescription)
        }
    }

    /// 安装应用（使用 osascript 请求管理员权限）
    private func installApp(from sourcePath: String) throws {
        DispatchQueue.main.async {
            self.state = .installing(progress: 0)
        }

        Logger.operation("静默安装", detail: "开始复制应用")

        let targetPath = "/Applications/WindowsSwitcher.app"
        let sourceAppPath = sourcePath

        // 使用 osascript 执行 AppleScript，会弹出系统授权对话框
        // 1. 先清除旧应用的扩展属性（避免指纹验证问题）
        // 2. 删除旧版本
        // 3. 使用 ditto 复制新版本（不保留隔离属性）
        // 4. 修复权限
        // 5. 清除新应用的扩展属性
        let script = """
        do shell script "if [ -d '\(targetPath)' ]; then xattr -cr '\(targetPath)'; rm -rf '\(targetPath)'; fi" with administrator privileges
        do shell script "ditto --noqtn --norsrc '\(sourceAppPath)' '\(targetPath)'" with administrator privileges
        do shell script "chmod -R 755 '\(targetPath)/Contents/MacOS/'" with administrator privileges
        do shell script "xattr -cr '\(targetPath)'" with administrator privileges
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.operation("静默安装", detail: "osascript 执行失败: \(error.localizedDescription)", result: "失败")
            throw InstallError.installFailed("执行安装脚本失败: \(error.localizedDescription)")
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            Logger.operation("静默安装", detail: "安装失败: \(errorMessage)", result: "失败")

            // 检查是否是用户取消
            if errorMessage.contains("User canceled") {
                throw InstallError.permissionDenied
            }

            throw InstallError.installFailed(errorMessage)
        }

        // 更新进度
        DispatchQueue.main.async {
            self.state = .installing(progress: 1.0)
            self.progress = 1.0
        }

        // 验证安装是否成功
        if !FileManager.default.fileExists(atPath: targetPath) {
            throw InstallError.installFailed("应用未成功复制到 Applications 目录")
        }

        Logger.operation("静默安装", detail: "应用复制完成")
    }

    /// 处理安装失败
    private func handleFailure(error: InstallError, completion: @escaping (Result<Void, InstallError>) -> Void) {
        Logger.operation("静默安装", detail: "安装失败: \(error.localizedDescription)", result: "失败")

        // 尝试回滚
        if let backupPath = backupPath {
            DispatchQueue.main.async {
                self.state = .rollback
            }

            do {
                // 使用 AppleScript 恢复备份
                let targetPath = "/Applications/WindowsSwitcher.app"
                let script = """
                tell application "System Events"
                    do shell script "if [ -d '\(targetPath)' ]; then rm -rf '\(targetPath)'; fi" with administrator privileges
                    do shell script "cp -R '\(backupPath.path)' '\(targetPath)'" with administrator privileges
                end tell
                """

                var errorInfo: NSDictionary?
                if let scriptObject = NSAppleScript(source: script) {
                    scriptObject.executeAndReturnError(&errorInfo)
                    if errorInfo != nil {
                        Logger.operation("静默安装", detail: "回滚失败", result: "失败")
                    }
                }
            }
        }

        // 清理：卸载 DMG
        if let mountPoint = mountPoint {
            try? Self.unmountDMG(mountPath: mountPoint)
        }

        DispatchQueue.main.async {
            self.state = .failed(error: error.localizedDescription)
            completion(.failure(error))
        }
    }

    /// 清理资源
    func cleanup() {
        // 卸载 DMG
        if let mountPoint = mountPoint {
            try? Self.unmountDMG(mountPath: mountPoint)
            self.mountPoint = nil
        }
    }

    // MARK: - 静态辅助方法

    /// 备份应用
    private static func backupApp() throws -> URL {
        let currentAppPath = Bundle.main.bundlePath

        Logger.operation("应用备份", detail: "开始备份: \(currentAppPath)")

        guard FileManager.default.fileExists(atPath: currentAppPath) else {
            throw InstallError.backupFailed("应用程序不存在")
        }

        // 创建备份目录
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let backupDir = appSupport.appendingPathComponent("WindowsSwitcher/Backups")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // 生成备份文件名
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupName = "WindowsSwitcher_\(version)_\(buildNumber)_\(timestamp).app"

        let backupPath = backupDir.appendingPathComponent(backupName)

        // 复制应用到备份目录
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: currentAppPath), to: backupPath)
            Logger.operation("应用备份", detail: "备份成功: \(backupPath.path)", result: "成功")
            return backupPath
        } catch {
            Logger.operation("应用备份", detail: "备份失败: \(error.localizedDescription)", result: "失败")
            throw InstallError.backupFailed(error.localizedDescription)
        }
    }

    /// 挂载 DMG 文件
    private static func mountDMGFile(dmgPath: URL) throws -> (mountPoint: String, appPath: String) {
        Logger.operation("DMG挂载", detail: "开始挂载: \(dmgPath.path)")

        // 使用 hdiutil attach 挂载 DMG
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-noautoopen", dmgPath.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallError.mountFailed("执行 hdiutil 失败: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            Logger.operation("DMG挂载", detail: "挂载失败: \(errorMessage)", result: "失败")
            throw InstallError.mountFailed(errorMessage)
        }

        // 解析输出获取挂载点
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw InstallError.mountFailed("无法解析挂载输出")
        }

        Logger.operation("DMG挂载", detail: "hdiutil 输出: \(output)")

        // 解析输出找到挂载点（/Volumes/...）
        // hdiutil 输出格式类似：
        // /dev/disk2              Apple_HFS                       /Volumes/WindowsSwitcher
        let lines = output.components(separatedBy: "\n")
        var mountPoint: String?

        for line in lines {
            // 查找包含 /Volumes/ 的行
            if let range = line.range(of: "/Volumes/") {
                // 提取挂载点路径（可能后面还有空格，需要trim）
                let mountPath = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                if !mountPath.isEmpty {
                    mountPoint = mountPath
                    break
                }
            }
        }

        guard let mountPoint = mountPoint else {
            Logger.operation("DMG挂载", detail: "无法解析挂载点", result: "失败")
            throw InstallError.mountFailed("无法解析挂载点")
        }

        Logger.operation("DMG挂载", detail: "解析到挂载点: \(mountPoint)")

        // 在挂载点中查找 .app 文件
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: mountPoint) else {
            Logger.operation("DMG挂载", detail: "无法读取挂载点内容: \(mountPoint)", result: "失败")
            throw InstallError.mountFailed("无法读取挂载点内容")
        }

        Logger.operation("DMG挂载", detail: "挂载点内容: \(contents)")

        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw InstallError.mountFailed("DMG 中未找到应用程序")
        }

        let appPath = (mountPoint as NSString).appendingPathComponent(appName)
        Logger.operation("DMG挂载", detail: "挂载成功: \(mountPoint), app: \(appPath)", result: "成功")

        return (mountPoint, appPath)
    }

    /// 卸载 DMG
    private static func unmountDMG(mountPath: String) throws {
        Logger.operation("DMG卸载", detail: "开始卸载: \(mountPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPath, "-force"]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.operation("DMG卸载", detail: "卸载异常: \(error.localizedDescription)", result: "警告")
            return
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            Logger.operation("DMG卸载", detail: "卸载失败: \(errorMessage)", result: "警告")
        } else {
            Logger.operation("DMG卸载", detail: "卸载成功", result: "成功")
        }
    }

    /// 验证应用签名
    private static func verifyCodeSign(appPath: URL) throws {
        Logger.operation("签名验证", detail: "开始验证: \(appPath.path)")

        // 检查应用是否存在
        guard FileManager.default.fileExists(atPath: appPath.path) else {
            throw InstallError.signatureInvalid("应用程序不存在")
        }

        // 使用 codesign 验证签名
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "--verbose=2", appPath.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallError.signatureInvalid("执行 codesign 失败: \(error.localizedDescription)")
        }

        // 读取输出
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            Logger.operation("签名验证", detail: "验证失败: \(errorOutput)", result: "失败")
            throw InstallError.signatureInvalid(errorOutput)
        }

        // 验证 Bundle Identifier
        let expectedBundleIdentifier = "com.moeasy.windowsswitcher"
        let plistPath = appPath.appendingPathComponent("Contents/Info.plist")
        guard let plistData = FileManager.default.contents(atPath: plistPath.path),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String else {
            Logger.operation("签名验证", detail: "无法读取 Bundle Identifier", result: "失败")
            throw InstallError.signatureInvalid("无法读取 Bundle Identifier")
        }

        guard bundleIdentifier == expectedBundleIdentifier else {
            Logger.operation("签名验证", detail: "Bundle Identifier 不匹配: \(bundleIdentifier)", result: "失败")
            throw InstallError.signatureInvalid("应用标识不匹配")
        }

        Logger.operation("签名验证", detail: "验证通过", result: "成功")
    }
}

// MARK: - 下载进度视图

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
                        ZAlignment(alignment: .leading) {
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

// MARK: - ZAlignment 辅助结构

/// 自定义 ZStack 对齐辅助
struct ZAlignment: Layout {
    var alignment: Alignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        return first.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            let x: CGFloat
            switch alignment.horizontal {
            case .leading: x = bounds.minX
            case .trailing: x = bounds.maxX - size.width
            default: x = bounds.midX - size.width / 2
            }
            subview.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: proposal)
        }
    }
}

// MARK: - 下载窗口控制器

/// 下载窗口控制器
class UpdateDownloadWindowController: NSWindowController, NSWindowDelegate {
    private var hostingView: NSHostingView<UpdateDownloadView>?
    private var onDismissHandler: (() -> Void)?

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
        if UpdateDownloadManager.shared.isDownloading {
            UpdateDownloadManager.shared.pauseDownload()
        }
        window?.close()
        onDismissHandler?()
    }

    func windowWillClose(_ notification: Notification) {
        if UpdateDownloadManager.shared.isDownloading {
            UpdateDownloadManager.shared.pauseDownload()
        }
        onDismissHandler?()
    }
}

// MARK: - 下载管理器

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
    private var _localFileURL: URL?

    /// 下载文件路径（公开访问）
    var localFileURL: URL? { _localFileURL }

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
        guard let fileURL = _localFileURL else {
            Logger.operation("安装更新", detail: "没有下载文件", result: "失败")
            return
        }

        // 检查是否启用静默安装
        if ConfigManager.shared.config.update.silentInstallEnabled {
            // 静默安装：发送通知显示安装进度窗口
            Logger.operation("安装更新", detail: "启动静默安装")
            NotificationCenter.default.post(name: .showInstallProgress, object: nil)
        } else {
            // 手动安装：打开 DMG
            Logger.operation("安装更新", detail: "打开文件: \(fileURL.path)")
            NSWorkspace.shared.open(fileURL)

            // 延迟删除临时文件
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.cleanupTempFile()
            }
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
        guard let url = _localFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        _localFileURL = nil
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
            self._localFileURL = destinationURL

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

// MARK: - 安装进度视图

/// 安装进度视图
struct InstallProgressView: View {
    @ObservedObject private var installer = SilentInstaller.shared
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

                Text("正在安装更新")
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

            // 进度区域
            VStack(spacing: 16) {
                // 状态文本
                Text(installer.state.message)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // 进度条（安装阶段显示）
                if case .installing(let progress) = installer.state {
                    VStack(spacing: 8) {
                        GeometryReader { geometry in
                            ZAlignment(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.blue)
                                    .frame(width: geometry.size.width * progress, height: 8)
                            }
                        }
                        .frame(height: 8)

                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }

                // 指示器
                switch installer.state {
                case .preparing, .backingUp, .mounting, .verifying:
                    ProgressView()
                        .scaleEffect(0.8)
                default:
                    EmptyView()
                }

                // 错误信息
                if case .failed(let error) = installer.state {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(24)

            Divider()
                .padding(.horizontal, 24)

            // 底部按钮
            HStack(spacing: 16) {
                switch installer.state {
                case .completed:
                    Button("重启应用") {
                        restartApp()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("稍后重启") {
                        installer.cleanup()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                case .failed:
                    Button("手动安装") {
                        if let fileURL = UpdateDownloadManager.shared.localFileURL {
                            NSWorkspace.shared.open(fileURL)
                        }
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("关闭") {
                        installer.cleanup()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                case .rollback:
                    Button("正在回滚...") {}
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(true)

                default:
                    Button("取消") {
                        installer.cleanup()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(true)
                }
            }
            .padding(24)
        }
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// 重启应用
    private func restartApp() {
        installer.cleanup()

        // 获取新版本应用路径
        let appPath = "/Applications/WindowsSwitcher.app"

        // 使用 NSWorkspace 启动新版本
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config) { _, error in
            if let error = error {
                Logger.operation("重启应用", detail: "启动失败: \(error.localizedDescription)", result: "失败")
                // 如果启动失败，尝试用 open 命令
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                }
            } else {
                Logger.operation("重启应用", detail: "启动成功", result: "成功")
            }

            // 退出当前应用
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - 安装进度窗口控制器

/// 安装进度窗口控制器
class InstallProgressWindowController: NSWindowController, NSWindowDelegate {
    private var hostingView: NSHostingView<InstallProgressView>?
    private var onDismissHandler: (() -> Void)?

    convenience init(onDismiss: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "安装更新"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        self.onDismissHandler = onDismiss
        window.delegate = self

        let view = InstallProgressView(onDismiss: { [weak self] in
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
        window?.close()
        onDismissHandler?()
    }

    func windowWillClose(_ notification: Notification) {
        onDismissHandler?()
    }
}
