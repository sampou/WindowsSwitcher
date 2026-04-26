import Foundation
import AppKit

/// Gitee Release API 响应模型
struct GiteeRelease: Codable {
    let tagName: String?         // 标签名，如 "v0.0.75"
    let name: String?            // 发布名称
    let body: String?            // 发布说明
    let htmlUrl: String?         // 页面地址
    let assets: [GiteeAsset]?    // 下载资源列表

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case assets
    }

    /// 用于测试的初始化方法
    init(tagName: String?, name: String?, body: String?, htmlUrl: String?, assets: [GiteeAsset]?) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlUrl = htmlUrl
        self.assets = assets
    }
}

/// Gitee 资源模型
struct GiteeAsset: Codable {
    let name: String?                // 文件名
    let browserDownloadUrl: String?  // 下载地址

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }

    /// 用于测试的初始化方法
    init(name: String?, browserDownloadUrl: String?) {
        self.name = name
        self.browserDownloadUrl = browserDownloadUrl
    }
}

/// 版本信息模型
struct VersionInfo {
    let version: String           // 版本号，如 "0.0.75"
    let buildNumber: Int          // 构建号（从版本号解析）
    let downloadURL: String       // 下载地址
    let releaseNotes: String?     // 更新说明
    let minSystemVersion: String? // 最低系统版本要求

    /// 从 Gitee Release 创建
    init?(from giteeRelease: GiteeRelease) {
        // 必须有 tag_name
        guard let tagName = giteeRelease.tagName else { return nil }

        // 解析版本号（去掉 "v" 前缀）
        var versionString = tagName
        if versionString.hasPrefix("v") {
            versionString = String(versionString.dropFirst())
        }

        self.version = versionString

        // 从版本号解析构建号（取最后一部分）
        let parts = versionString.split(separator: ".")
        self.buildNumber = parts.last.flatMap { Int($0) } ?? 0

        // 获取下载地址（优先 DMG）
        if let assets = giteeRelease.assets {
            if let dmgAsset = assets.first(where: { $0.name?.hasSuffix(".dmg") ?? false }),
               let downloadUrl = dmgAsset.browserDownloadUrl {
                self.downloadURL = downloadUrl
            } else if let zipAsset = assets.first(where: { $0.name?.hasSuffix(".zip") ?? false }),
                      let downloadUrl = zipAsset.browserDownloadUrl {
                self.downloadURL = downloadUrl
            } else if let firstAsset = assets.first,
                      let downloadUrl = firstAsset.browserDownloadUrl {
                self.downloadURL = downloadUrl
            } else {
                // 没有资源，使用页面地址
                self.downloadURL = giteeRelease.htmlUrl ?? "https://gitee.com/sampou/WindowsSwitcher/releases"
            }
        } else {
            self.downloadURL = giteeRelease.htmlUrl ?? "https://gitee.com/sampou/WindowsSwitcher/releases"
        }

        self.releaseNotes = giteeRelease.body
        self.minSystemVersion = nil
    }
}

/// 版本检查服务
class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published var isChecking = false
    @Published var latestVersion: VersionInfo?
    @Published var updateAvailable = false
    @Published var errorMessage: String?

    private let config = ConfigManager.shared
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
        // 从配置中获取 API URL
        let urlString = config.config.update.apiURL
        Logger.operation("版本检查", detail: "开始检查, URL: \(urlString)")
        Logger.operation("版本检查", detail: "当前版本: \(currentVersion), build: \(currentBuildNumber)")

        guard let url = URL(string: urlString) else {
            Logger.operation("版本检查", detail: "URL 无效", result: "失败")
            await MainActor.run {
                self.errorMessage = "未配置版本检查地址"
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
            let giteeRelease = try JSONDecoder().decode(GiteeRelease.self, from: data)
            Logger.operation("版本检查", detail: "API 返回版本: \(giteeRelease.tagName)")

            // 转换为 VersionInfo
            guard let versionInfo = VersionInfo(from: giteeRelease) else {
                Logger.operation("版本检查", detail: "解析版本信息失败", result: "失败")
                await MainActor.run {
                    self.errorMessage = "无法解析版本信息"
                    self.isChecking = false
                }
                return
            }

            let hasUpdate = self.isNewVersionAvailable(versionInfo)
            Logger.operation("版本检查", detail: "有新版本: \(hasUpdate)", result: hasUpdate ? "是" : "否")

            await MainActor.run {
                self.latestVersion = versionInfo
                self.updateAvailable = hasUpdate
                self.isChecking = false
            }
        } catch {
            Logger.operation("版本检查", detail: "检查失败: \(error.localizedDescription)", result: "失败")
            await MainActor.run {
                self.errorMessage = "检查更新失败: \(error.localizedDescription)"
                self.isChecking = false
            }
        }
    }

    /// 检查更新并显示全局弹窗
    func checkForUpdateAndShowAlert() async {
        await checkForUpdate()

        // 如果有新版本，发送通知显示更新窗口
        if updateAvailable {
            await MainActor.run {
                NotificationCenter.default.post(name: .updateAvailable, object: nil)
            }
        }
    }

    // MARK: - 自动检查

    /// 启动自动检查定时器
    func startAutoCheck() {
        stopAutoCheck()

        let interval = config.config.update.checkInterval
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
            // 使用配置中的发布页面地址
            if let releasesURL = URL(string: config.config.update.releasesPageURL) {
                NSWorkspace.shared.open(releasesURL)
            }
            return
        }
        NSWorkspace.shared.open(downloadURL)
    }
}
