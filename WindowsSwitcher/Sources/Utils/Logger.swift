import Foundation
import os.log

// MARK: - 通知名称扩展
extension Notification.Name {
    static let updateAvailable = Notification.Name("updateAvailable")
}

class Logger {
    enum WindowLifecycleEvent: String {
        case created = "创建"
        case destroyed = "销毁"
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.moeasy.windowsswitcher"

    private static let core = OSLog(subsystem: subsystem, category: "Core")
    private static let ui = OSLog(subsystem: subsystem, category: "UI")
    private static let perf = OSLog(subsystem: subsystem, category: "Performance")
    private static let operation = OSLog(subsystem: subsystem, category: "Operation")

    // MARK: - 时间格式化（系统时区）
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current // 使用系统当前时区
        return formatter
    }()

    /// 获取当前时间戳（系统时间）
    private static func timestamp() -> String {
        return dateFormatter.string(from: Date())
    }

    // MARK: - 文件日志配置
    private static let logFileURL: URL = {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Logs/WindowsSwitcher")

        // 创建日志目录
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        return logsDir.appendingPathComponent("operations.log")
    }()

    // 日志文件最大大小 (5MB)
    private static let maxLogFileSize: Int64 = 5 * 1024 * 1024

    // 日志写入队列（后台队列，避免阻塞主线程）
    private static let logQueue = DispatchQueue(label: "com.moeasy.windowsswitcher.logQueue", qos: .utility)

    /// 写入日志到文件（异步，不阻塞主线程）
    private static func writeToFile(_ message: String) {
        logQueue.async {
            // 检查文件大小，超过限制则轮转
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
               let fileSize = attrs[.size] as? Int64,
               fileSize > maxLogFileSize {
                // 轮转日志：删除旧日志，重新开始
                try? FileManager.default.removeItem(at: logFileURL)
            }

            // 追加写入
            guard let data = (message + "\n").data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    // MARK: - 操作日志（追踪用户操作流程）

    /// 记录用户操作，便于问题诊断
    /// - Parameters:
    ///   - action: 操作名称（如 "面板显示"、"窗口选择"、"修饰键释放"）
    ///   - detail: 操作详情
    ///   - result: 操作结果（可选）
    static func operation(_ action: String, detail: String, result: String? = nil,
                          file: String = #file, function: String = #function, line: Int = #line) {
        let tag = "\((file as NSString).lastPathComponent):\(line)"

        var message = "[\(timestamp())] 📍 \(action) | \(detail)"
        if let result = result {
            message += " | 结果: \(result)"
        }

        os_log(.info, log: operation, "%{public}@ | %{public}@", tag, message)

        // 写入文件（异步，不阻塞）
        writeToFile(message)
    }

    /// 记录面板状态变化
    static func panelState(_ state: String, detail: String = "",
                          file: String = #file, function: String = #function, line: Int = #line) {
        operation("面板状态", detail: state + (detail.isEmpty ? "" : " - \(detail)"),
                  file: file, function: function, line: line)
    }

    /// 记录窗口选择
    static func windowSelect(_ method: String, windowInfo: String,
                            file: String = #file, function: String = #function, line: Int = #line) {
        operation("窗口选择", detail: "\(method) -> \(windowInfo)",
                  file: file, function: function, line: line)
    }

    /// 记录窗口激活
    static func windowActivate(_ windowInfo: String, result: String,
                               file: String = #file, function: String = #function, line: Int = #line) {
        operation("窗口激活", detail: windowInfo, result: result,
                  file: file, function: function, line: line)
    }

    /// 记录窗口创建事件。仅供低频生命周期事件使用，内容会写入 operations.log。
    static func windowCreated(windowID: UInt32, appName: String, windowTitle: String,
                              bundleIdentifier: String,
                              file: String = #file, function: String = #function, line: Int = #line) {
        operation(
            "窗口生命周期",
            detail: windowLifecycleDetail(
                event: .created,
                windowID: windowID,
                appName: appName,
                windowTitle: windowTitle,
                bundleIdentifier: bundleIdentifier
            ),
            file: file,
            function: function,
            line: line
        )
    }

    /// 记录窗口销毁事件。销毁事件仅保留窗口 ID，避免依赖已失效的窗口元数据。
    static func windowDestroyed(windowID: UInt32,
                                file: String = #file, function: String = #function, line: Int = #line) {
        operation(
            "窗口生命周期",
            detail: windowLifecycleDetail(event: .destroyed, windowID: windowID),
            file: file,
            function: function,
            line: line
        )
    }

    /// 生成可确定性测试的窗口生命周期结构化字段。
    static func windowLifecycleDetail(event: WindowLifecycleEvent, windowID: UInt32,
                                      appName: String? = nil, windowTitle: String? = nil,
                                      bundleIdentifier: String? = nil) -> String {
        var fields = ["事件=\(event.rawValue)", "窗口ID=\(windowID)"]

        if event == .created {
            fields.append("应用=\(normalizedLifecycleValue(appName))")
            fields.append("标题=\(normalizedLifecycleValue(windowTitle))")
            fields.append("BundleID=\(normalizedLifecycleValue(bundleIdentifier))")
        }

        return fields.joined(separator: " | ")
    }

    private static func normalizedLifecycleValue(_ value: String?) -> String {
        guard let value else { return "未知" }

        let normalized = value
            .replacingOccurrences(of: "|", with: "／")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "未知" : normalized
    }

    /// 记录修饰键状态
    static func modifierState(_ state: String, detail: String = "",
                              file: String = #file, function: String = #function, line: Int = #line) {
        operation("修饰键", detail: state + (detail.isEmpty ? "" : " - \(detail)"),
                  file: file, function: function, line: line)
    }

    /// 记录修饰键变化（详细版）
    static func flagsChanged(_ info: String,
                             file: String = #file, function: String = #function, line: Int = #line) {
        operation("修饰键变化", detail: info,
                  file: file, function: function, line: line)
    }

    /// 记录键盘事件
    static func keyEvent(_ key: String, action: String,
                        file: String = #file, function: String = #function, line: Int = #line) {
        operation("键盘事件", detail: "\(key) - \(action)",
                  file: file, function: function, line: line)
    }

    static func debug(_ message: String, category: OSLog = core,
                      file: String = #file, function: String = #function, line: Int = #line) {
        let tag = "\((file as NSString).lastPathComponent):\(line) \(function)"
        os_log(.debug, log: category, "%{public}@ | %{public}@", tag, message)
    }

    static func info(_ message: String, category: OSLog = core,
                     file: String = #file, function: String = #function, line: Int = #line) {
        let tag = "\((file as NSString).lastPathComponent):\(line)"
        os_log(.info, log: category, "%{public}@ | %{public}@", tag, message)
    }

    static func warning(_ message: String, category: OSLog = core,
                        file: String = #file, function: String = #function, line: Int = #line) {
        let tag = "\((file as NSString).lastPathComponent):\(line)"
        os_log(.default, log: category, "⚠️ %{public}@ | %{public}@", tag, message)
    }

    static func error(_ message: String, category: OSLog = core,
                      file: String = #file, function: String = #function, line: Int = #line) {
        let tag = "\((file as NSString).lastPathComponent):\(line)"
        os_log(.error, log: category, "❌ %{public}@ | %{public}@", tag, message)
    }

    static func measure<T>(_ label: String, block: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = block()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        os_log(.debug, log: perf, "⏱ %{public}@ took %.2fms", label, ms)
        return result
    }
}
