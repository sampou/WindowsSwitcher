import Foundation
import os.log

class Logger {
    private static let subsystem = "com.windowsswitcher.app"

    private static let core = OSLog(subsystem: subsystem, category: "Core")
    private static let ui = OSLog(subsystem: subsystem, category: "UI")
    private static let perf = OSLog(subsystem: subsystem, category: "Performance")

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
