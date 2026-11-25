import Foundation
import Combine

// MARK: - 通知名称扩展
extension Notification.Name {
    static let hotKeysDidChange = Notification.Name("hotKeysDidChange")
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    private let key = "com.windowsswitcher.config"
    /// 配置 schema 版本号，用于未来不兼容变更时做迁移判断
    private static let versionKey = "com.windowsswitcher.config.version"
    /// 解码失败时原数据的备份键。备份永不覆盖已存在的备份，避免损坏数据把好备份顶掉。
    private static let backupKey = "com.windowsswitcher.config.backup"

    @Published var config: ConfigModel {
        didSet {
            trySave()
            // 检查快捷键是否变化
            if oldValue.hotKeys != config.hotKeys {
                NotificationCenter.default.post(name: .hotKeysDidChange, object: nil)
            }
            if oldValue.appearance.language != config.appearance.language {
                NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
            }
        }
    }
    @Published var saveError: String? = nil

    private init() {
        config = Self.load(forKey: key)
    }

    // MARK: - Persistence

    private static func load(forKey key: String) -> ConfigModel {
        guard let data = UserDefaults.standard.data(forKey: key) else { return ConfigModel() }
        do {
            return try JSONDecoder().decode(ConfigModel.self, from: data)
        } catch {
            // 解码失败意味着配置损坏或不兼容：先把原数据留档供找回，
            // 绝不静默丢弃，然后回退默认配置继续运行。
            let defaults = UserDefaults.standard
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(data, forKey: backupKey)
            }
            Logger.error("配置解码失败，原数据已备份到 \(backupKey)：\(error)")
            return ConfigModel()
        }
    }

    private func trySave() {
        do {
            let data = try JSONEncoder().encode(config)
            let defaults = UserDefaults.standard
            defaults.set(data, forKey: key)
            defaults.set(ConfigModel.currentVersion, forKey: Self.versionKey)
            defaults.synchronize()
            if saveError != nil { saveError = nil }
        } catch {
            saveError = L10n.format("设置保存失败：%@", error.localizedDescription)
        }
    }

    func reset() {
        config = ConfigModel()
    }

    // MARK: - Section helpers

    func updateAppearance(_ block: (inout AppearanceConfig) -> Void) {
        var appearance = config.appearance
        block(&appearance)
        config.appearance = appearance
    }

    func updateBehavior(_ block: (inout BehaviorConfig) -> Void) {
        var behavior = config.behavior
        block(&behavior)
        config.behavior = behavior
    }

    func updateHotKeys(_ block: (inout HotKeyConfig) -> Void) {
        var hotKeys = config.hotKeys
        block(&hotKeys)
        config.hotKeys = hotKeys
    }

    func updateDockPreview(_ block: (inout DockPreviewConfig) -> Void) {
        var dockPreview = config.dockPreview
        block(&dockPreview)

        // 边界验证
        dockPreview.hoverDelay = max(0.05, min(1.0, dockPreview.hoverDelay))
        dockPreview.hideDelay = max(0.05, min(1.0, dockPreview.hideDelay))
        dockPreview.maxPreviewCount = max(2, min(16, dockPreview.maxPreviewCount))
        dockPreview.previewWidth = max(50, min(200, dockPreview.previewWidth))
        dockPreview.previewHeight = max(30, min(120, dockPreview.previewHeight))
        dockPreview.verticalSpacing = max(4, min(30, dockPreview.verticalSpacing))    // 4-30px
        dockPreview.horizontalSpacing = max(4, min(30, dockPreview.horizontalSpacing)) // 4-30px

        config.dockPreview = dockPreview
    }
}
