import Foundation

/// 文件对话框适配器协议。
///
/// 适配器只负责「识别某一类文件选择器」与「在该选择器上执行导航」，
/// 不参与事件拦截流程，新增第三方应用时不需要改动拦截链路。
protocol FileDialogAdapter {

    var identifier: String { get }

    /// 是否支持该应用（按 bundleID / 版本判定）。
    func supportsApplication(bundleID: String, processID: pid_t) -> Bool

    /// 识别当前上下文对应的对话框。
    func detect(_ context: DialogContext) -> AdapterConfidence

    /// 执行目录导航。
    func navigate(to directory: URL, in context: DialogContext) async throws
}

/// 适配器清单：用于记录适配范围与限制，避免"看起来像"就放行。
struct AdapterManifest {
    let identifier: String
    let bundleIDs: Set<String>
    let minimumVersion: String?
    let maximumTestedVersion: String?
    let navigationStrategy: String
}

/// 适配器注册表。
///
/// 适配器按优先级排列；命中第一个 `confirmed` 的适配器即停止匹配，
/// 避免多个适配器同时认领同一个窗口。
final class AdapterRegistry {

    private let adapters: [FileDialogAdapter]

    init(adapters: [FileDialogAdapter]) {
        self.adapters = adapters
    }

    func match(_ context: DialogContext) -> (adapter: FileDialogAdapter, confidence: AdapterConfidence)? {
        for adapter in adapters {
            guard adapter.supportsApplication(bundleID: context.bundleID,
                                              processID: context.processID) else {
                continue
            }
            let confidence = adapter.detect(context)
            if confidence == .confirmed {
                return (adapter, confidence)
            }
        }
        return nil
    }
}
