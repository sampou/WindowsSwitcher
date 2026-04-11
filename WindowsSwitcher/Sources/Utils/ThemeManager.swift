import AppKit
import SwiftUI
import Combine

// T-037: Theme switching (light / dark / auto)

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var effectiveColorScheme: ColorScheme
    @Published private(set) var effectiveAppearance: NSAppearance

    private var cancellables = Set<AnyCancellable>()

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private init() {
        // 初始化时使用系统主题
        let systemScheme = Self.getCurrentSystemColorScheme()
        effectiveColorScheme = systemScheme
        effectiveAppearance = systemScheme == .dark ? NSAppearance(named: .darkAqua)! : NSAppearance(named: .aqua)!

        // 延迟到下一个 RunLoop 再订阅，避免初始化期间的视图更新问题
        DispatchQueue.main.async { [weak self] in
            self?.setupBindings()
        }
    }

    private func setupBindings() {
        // React to config changes
        ConfigManager.shared.$config
            .map(\.appearance.theme)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.apply(theme)
            }
            .store(in: &cancellables)

        // React to system appearance changes when theme == .auto
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        // 初始化时应用配置的主题
        let initialTheme = ConfigManager.shared.config.appearance.theme
        apply(initialTheme)
    }

    @objc private func systemAppearanceChanged() {
        guard ConfigManager.shared.config.appearance.theme == .auto else { return }

        DispatchQueue.main.async { [weak self] in
            self?.applySystemTheme()
        }
    }

    private func apply(_ theme: AppTheme) {
        switch theme {
        case .light:
            effectiveColorScheme = .light
            effectiveAppearance = NSAppearance(named: .aqua)!
        case .dark:
            effectiveColorScheme = .dark
            effectiveAppearance = NSAppearance(named: .darkAqua)!
        case .auto:
            applySystemTheme()
        }
    }

    private func applySystemTheme() {
        let scheme = Self.getCurrentSystemColorScheme()
        effectiveColorScheme = scheme
        effectiveAppearance = scheme == .dark ? NSAppearance(named: .darkAqua)! : NSAppearance(named: .aqua)!
    }

    private static func getCurrentSystemColorScheme() -> ColorScheme {
        // 使用 NSApp.effectiveAppearance 判断当前系统主题
        if let appearance = NSApp?.effectiveAppearance {
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
        // 默认返回浅色
        return .light
    }
}
