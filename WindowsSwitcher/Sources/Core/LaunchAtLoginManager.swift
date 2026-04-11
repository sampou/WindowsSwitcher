import Foundation
import ServiceManagement
import AppKit

/// 开机启动管理器
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false {
        didSet {
            if oldValue != isEnabled {
                setLaunchAtLogin(isEnabled)
            }
        }
    }

    private init() {
        syncStatus()
    }

    /// 同步系统实际状态
    func syncStatus() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        Logger.info("开机启动状态同步: \(isEnabled)")
    }

    /// 设置开机启动
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Logger.info("已启用开机启动")
            } else {
                try SMAppService.mainApp.unregister()
                Logger.info("已禁用开机启动")
            }
        } catch {
            Logger.error("设置开机启动失败: \(error.localizedDescription)")
            // 恢复原状态
            DispatchQueue.main.async {
                self.isEnabled = !enabled
            }
        }
    }

    /// 切换开机启动状态
    func toggle() {
        isEnabled.toggle()
    }
}
