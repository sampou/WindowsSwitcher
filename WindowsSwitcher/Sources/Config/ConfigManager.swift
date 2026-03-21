import Foundation

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    private let key = "com.windowsswitcher.config"

    @Published var config: ConfigModel {
        didSet { trySave() }
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
            saveError = "设置保存失败：\(error.localizedDescription)"
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
}
