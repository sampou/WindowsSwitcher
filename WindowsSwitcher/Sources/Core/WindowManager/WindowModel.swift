import AppKit
import CoreGraphics

// MARK: - 非标准窗口识别规则
struct NonStandardWindowRules {
    /// 系统应用 Bundle ID 列表（这些应用的窗口不显示在预览中）
    static let excludedBundleIDs: Set<String> = [
        // macOS 系统组件
        "com.apple.dock",                        // Dock
        "com.apple.notificationcenterui",        // 通知中心
        "com.apple.systemuiserver",              // 系统 UI 服务
        "com.apple.WindowServer",                // 窗口服务器
        "com.apple.PIPAgent",                    // 画中画代理
        "com.apple.screencaptureui",             // 截图工具
        "com.apple.controlcenter",               // 控制中心
        "com.apple.menuextra",                   // 菜单栏扩展
        "com.apple.Spotlight",                   // Spotlight
        "com.apple.loginwindow",                 // 登录窗口
        "com.apple.ScreenSaver.Engine",          // 屏幕保护
        "com.apple.WindowManager",               // 窗口管理器
        "com.apple.AVConference",                // FaceTime 服务
        "com.apple.FaceTime",                    // FaceTime（通话中的覆盖层）
        // 常见的非标准窗口应用
        "com.manytricks.Magnet",                 // Magnet 窗口管理
        "com.crowdcafe.windowmagnet",            // Magnet
        "com.divisiblebyzero.Spectacle",         // Spectacle
        "com.knollsoft.Rectangle",               // Rectangle
    ]

    /// 系统应用名称列表（用于 Bundle ID 为空时的降级判断）
    static let excludedAppNames: Set<String> = [
        "Dock",
        "Window Server",
        "SystemUIServer",
        "NotificationCenter",
        "Control Center",
        "Spotlight",
        "ScreenSaverEngine",
        "loginwindow",
        "WindowManager",
        "PIPAgent",
    ]

    /// 判断是否为非标准窗口
    /// - Parameters:
    ///   - bundleIdentifier: 应用 Bundle ID
    ///   - appName: 应用名称
    ///   - windowTitle: 窗口标题
    ///   - frame: 窗口尺寸
    ///   - windowLayer: 窗口层级
    /// - Returns: 是否为非标准窗口
    static func isNonStandardWindow(
        bundleIdentifier: String,
        appName: String,
        windowTitle: String,
        frame: CGRect,
        windowLayer: Int
    ) -> Bool {
        // 1. 窗口层级检查：非 0 层级的窗口通常是系统覆盖层
        if windowLayer != 0 {
            return true
        }

        // 2. Bundle ID 检查
        if excludedBundleIDs.contains(bundleIdentifier) {
            return true
        }

        // 3. 应用名称检查（降级方案）
        let lowerAppName = appName.lowercased()
        for excludedName in excludedAppNames {
            if lowerAppName.contains(excludedName.lowercased()) {
                return true
            }
        }

        // 4. 尺寸检查：尺寸异常的窗口
        if frame.width <= 0 || frame.height <= 0 {
            return true
        }

        // 5. 超大窗口检查：超过屏幕尺寸的窗口可能是系统覆盖层
        // 典型的 5K 显示器分辨率为 5120x2880，超过这个尺寸的窗口通常是系统级的
        if frame.width > 6000 || frame.height > 4000 {
            return true
        }

        // 6. 极小窗口检查：可能是系统托盘图标等
        // 小于 50x50 的窗口通常是图标或按钮，不是真正的窗口
        if frame.width < 50 && frame.height < 50 {
            return true
        }

        // 7. 无应用名且无标题的窗口
        if appName.isEmpty || appName == "Unknown" {
            if windowTitle.isEmpty {
                return true
            }
        }

        return false
    }

    /// 辅助功能窗口的角色用于补充 CGWindow 的 layer 判断。
    /// 浏览器的搜索框、弹出面板等可能同样位于 layer 0，只有通过 AXSubrole 才能与主窗口区分。
    /// 角色缺失时保守放行，避免因应用未完整实现辅助功能接口而遗漏正常窗口。
    static func isStandardAccessibilityWindow(role: String?, subrole: String?) -> Bool {
        guard let role else { return true }
        guard role == "AXWindow" else { return false }
        guard let subrole, !subrole.isEmpty else { return true }
        return subrole == "AXStandardWindow"
    }
}

struct WindowModel: Identifiable, Equatable {
    let id: CGWindowID
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String
    let appIcon: NSImage
    let frame: CGRect
    let isMinimized: Bool
    let isHidden: Bool
    let isOnScreen: Bool
    let lastActiveTime: Date
    let windowLayer: Int
    let ownerPID: pid_t

    /// 是否为标准窗口（可用于预览）
    let isStandardWindow: Bool

    static func == (lhs: WindowModel, rhs: WindowModel) -> Bool {
        lhs.id == rhs.id
    }
}
