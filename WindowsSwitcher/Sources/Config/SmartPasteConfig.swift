import Foundation

/// 智能目录粘贴配置。
///
/// 编码策略与 `BehaviorConfig` 保持一致：缺失字段回落到默认值，
/// 避免旧版本配置文件解码失败导致用户设置被整体重置。
struct SmartPasteConfig: Codable, Equatable {

    /// 总开关。默认关闭，由用户主动开启。
    var enabled: Bool = false
    /// 导航执行超时（秒）。
    var navigationTimeout: Double = 1.5
    /// 失败时是否显示非模态提示。
    var showFailureToast: Bool = true
    /// 第三方应用白名单（bundleID）。空数组表示只支持原生面板。
    var allowedBundleIDs: [String] = []
    /// 是否在诊断日志中记录完整目录路径。默认关闭：路径可能包含敏感信息。
    var logDirectoryPaths: Bool = false
    /// 是否启用右键跳转：在文件面板中右键直接跳转到剪贴板中的目录。
    var rightClickJumpEnabled: Bool = true
    /// 右键跳转时是否抑制系统原生右键菜单。
    ///
    /// 开启时该次右键不会弹出系统菜单：跳转策略可能需要发送合成按键，
    /// 而系统菜单处于打开状态会吞掉这些按键。
    var suppressSystemContextMenu: Bool = true

    private enum CodingKeys: String, CodingKey {
        case enabled, navigationTimeout, showFailureToast, allowedBundleIDs, logDirectoryPaths
        case rightClickJumpEnabled, suppressSystemContextMenu
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        navigationTimeout = try container.decodeIfPresent(Double.self, forKey: .navigationTimeout) ?? 1.5
        showFailureToast = try container.decodeIfPresent(Bool.self, forKey: .showFailureToast) ?? true
        allowedBundleIDs = try container.decodeIfPresent([String].self, forKey: .allowedBundleIDs) ?? []
        logDirectoryPaths = try container.decodeIfPresent(Bool.self, forKey: .logDirectoryPaths) ?? false
        rightClickJumpEnabled = try container.decodeIfPresent(Bool.self, forKey: .rightClickJumpEnabled) ?? true
        suppressSystemContextMenu = try container.decodeIfPresent(Bool.self, forKey: .suppressSystemContextMenu) ?? true
    }
}
