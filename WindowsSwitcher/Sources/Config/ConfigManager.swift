import Foundation

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    private let key = "com.windowsswitcher.config"

    @Published var config: ConfigModel {
        didSet { save() }
    }

    private init() {
        config = Self.load(forKey: key)
    }

    // MARK: - Persistence

    private static func load(forKey key: String) -> ConfigModel {
        guard let data = UserDefaults.standard.data(forKey: key) else { return ConfigModel() }
        // Partial-decode resilience: fall back to default on any schema mismatch
        return (try? JSONDecoder().decode(ConfigModel.self, from: data)) ?? ConfigModel()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.synchronize() // ensure flush before termination
    }

    func reset() {
        config = ConfigModel()
    }

    // MARK: - Section helpers (T-036, T-038)

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
