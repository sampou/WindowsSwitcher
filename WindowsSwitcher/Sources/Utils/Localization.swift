import Foundation

/// 应用界面文案的统一本地化入口。
///
/// 第一阶段根据系统首选语言自动选择简体中文或英文；当翻译缺失时返回中文 key，
/// 以保证界面始终可读。
enum L10n {
    /// 供 SwiftUI 注入的界面语言环境。
    static var locale: Locale {
        guard let identifier = ConfigManager.shared.config.appearance.language.localizationIdentifier else {
            return .current
        }
        return Locale(identifier: identifier)
    }

    /// 当前偏好对应的资源包。手动选择时只切换本应用文案，不修改 macOS 全局语言。
    private static var bundle: Bundle {
        guard let identifier = ConfigManager.shared.config.appearance.language.localizationIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return .main
        }
        return localizedBundle
    }

    /// 返回本地化后的静态文案。
    static func text(_ key: String, comment: String = "") -> String {
        NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: bundle,
            value: key,
            comment: comment
        )
    }

    /// 返回带字符串占位参数的本地化文案。
    ///
    /// 本项目本地化资源统一使用 `%@`。限制参数为 `String` 可以在编译期阻止把整数等标量
    /// 当作 Objective-C 对象地址传入，从而避免 Foundation 格式化时发生非法内存访问。
    static func format(_ key: String, _ arguments: String..., comment: String = "") -> String {
        let format = text(key, comment: comment)
        let objectArguments: [CVarArg] = arguments.map { $0 as NSString }
        return withVaList(objectArguments) { pointer in
            NSString(format: format, locale: locale, arguments: pointer) as String
        }
    }
}
