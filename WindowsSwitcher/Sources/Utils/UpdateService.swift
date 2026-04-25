import Foundation
import AppKit

/// 版本信息模型
struct VersionInfo: Codable {
    let version: String           // 最新版本号，如 "0.0.68"
    let buildNumber: Int          // 构建号
    let downloadURL: String       // 下载地址
    let releaseNotes: String?     // 更新说明
    let minSystemVersion: String? // 最低系统版本要求
}

/// 版本检查服务
class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published var isChecking = false
    @Published var latestVersion: VersionInfo?
    @Published var updateAvailable = false
    @Published var errorMessage: String?

    // 版本检查 URL（后期提供）
    private var checkURL: URL? {
        // TODO: 后期提供实际的版本检查 URL
        // return URL(string: "https://example.com/version.json")
        return nil
    }

    private var autoCheckTimer: Timer?

    private init() {}

    // MARK: - 当前版本信息

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var currentBuildNumber: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    // MARK: - 版本比较

    /// 比较版本号，返回 true 表示有新版本
    func isNewVersionAvailable(_ latest: VersionInfo) -> Bool {
        // 先比较构建号
        if latest.buildNumber > currentBuildNumber {
            return true
        }

        // 再比较版本号
        let currentParts = currentVersion.split(separator: ".").compactMap { Int($0) }
        let latestParts = latest.version.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(currentParts.count, latestParts.count) {
            let current = i < currentParts.count ? currentParts[i] : 0
            let latestVal = i < latestParts.count ? latestParts[i] : 0

            if latestVal > current {
                return true
            } else if latestVal < current {
                return false
            }
        }

        return false
    }

    // MARK: - 检查更新

    /// 检查是否有新版本
    func checkForUpdate() async {
        guard let url = checkURL else {
            // 没有配置检查 URL，模拟检查成功但无更新
            await MainActor.run {
                self.errorMessage = nil
                self.updateAvailable = false
                self.isChecking = false
            }
            return
        }

        await MainActor.run {
            self.isChecking = true
            self.errorMessage = nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let versionInfo = try JSONDecoder().decode(VersionInfo.self, from: data)

            await MainActor.run {
                self.latestVersion = versionInfo
                self.updateAvailable = self.isNewVersionAvailable(versionInfo)
                self.isChecking = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "检查更新失败: \(error.localizedDescription)"
                self.isChecking = false
            }
        }
    }

    /// 检查更新并显示全局弹窗
    func checkForUpdateAndShowAlert() async {
        await checkForUpdate()

        // 如果有新版本，显示全局弹窗
        if updateAvailable {
            await MainActor.run {
                showUpdateAlert()
            }
        }
    }

    /// 显示更新弹窗（全局）
    func showUpdateAlert() {
        // 激活应用
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "发现新版本"

        if let latest = latestVersion {
            alert.informativeText = """
            版本 \(latest.version) 已发布

            \(latest.releaseNotes ?? "建议更新以获得最新功能。")
            """
        } else {
            alert.informativeText = "有新版本可用，建议更新。"
        }

        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即下载")
        alert.addButton(withTitle: "稍后提醒")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            openDownloadPage()
        }
    }

    // MARK: - 自动检查

    /// 启动自动检查定时器
    func startAutoCheck() {
        stopAutoCheck()

        let interval = ConfigManager.shared.config.update.checkInterval
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.checkForUpdateAndShowAlert()
            }
        }

        // 立即检查一次
        Task {
            await checkForUpdateAndShowAlert()
        }
    }

    /// 停止自动检查
    func stopAutoCheck() {
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
    }

    // MARK: - 下载和安装

    /// 下载更新
    func downloadUpdate(from url: URL) async -> URL? {
        do {
            let (localURL, _) = try await URLSession.shared.download(from: url)
            return localURL
        } catch {
            await MainActor.run {
                self.errorMessage = "下载失败: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// 安装更新（打开 DMG 文件）
    func installUpdate(from fileURL: URL) {
        NSWorkspace.shared.open(fileURL)
    }

    /// 在浏览器中打开下载页面
    func openDownloadPage() {
        guard let url = latestVersion?.downloadURL,
              let downloadURL = URL(string: url) else {
            // 使用默认的 GitHub releases 页面
            if let githubURL = URL(string: "https://github.com/jnMetaCode/agency-agents-zh/releases") {
                NSWorkspace.shared.open(githubURL)
            }
            return
        }
        NSWorkspace.shared.open(downloadURL)
    }
}
