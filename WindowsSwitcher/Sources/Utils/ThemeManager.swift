import AppKit
import SwiftUI
import Combine

// T-037: Theme switching (light / dark / auto)

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var effectiveColorScheme: ColorScheme = .light

    private var cancellables = Set<AnyCancellable>()

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private init() {
        // React to config changes
        ConfigManager.shared.$config
            .map(\.appearance.theme)
            .removeDuplicates()
            .sink { [weak self] theme in self?.apply(theme) }
            .store(in: &cancellables)

        // React to system appearance changes when theme == .auto
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemAppearanceChanged() {
        if ConfigManager.shared.config.appearance.theme == .auto {
            effectiveColorScheme = systemColorScheme
        }
    }

    private func apply(_ theme: AppTheme) {
        switch theme {
        case .light: effectiveColorScheme = .light
        case .dark:  effectiveColorScheme = .dark
        case .auto:  effectiveColorScheme = systemColorScheme
        }
    }

    private var systemColorScheme: ColorScheme {
        guard let app = NSApp else { return .light }
        return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
