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
        return (try? JSONDecoder().decode(ConfigModel.self, from: data)) ?? ConfigModel()
    }

    private func trySave() {
        do {
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: key)
            UserDefaults.standard.synchronize()
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
