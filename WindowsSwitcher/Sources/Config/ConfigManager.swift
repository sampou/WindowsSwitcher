import Foundation

class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    private let key = "com.windowsswitcher.config"

    @Published var config: ConfigModel {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ConfigModel.self, from: data) {
            config = decoded
        } else {
            config = ConfigModel()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func reset() {
        config = ConfigModel()
    }
}
