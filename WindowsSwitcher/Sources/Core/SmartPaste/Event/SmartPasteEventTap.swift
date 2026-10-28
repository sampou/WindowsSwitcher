import Foundation
import CoreGraphics

enum SmartPasteEventTapError: Error {
    case creationFailed
}

/// 常驻的 ⌘V 拦截事件 tap。
///
/// 与 `AppDelegate` 中按需创建的 ESC tap 相互独立：本 tap 跟随功能开关常驻，
/// 回调中只做 O(1) 的快照读取，任何 AX 查询、文件系统访问都必须放到回调之外。
final class SmartPasteEventTap {

    /// 快照读取闭包；由协调器注入。
    var resolveSnapshot: (() -> PasteEligibilitySnapshot?)?
    /// 拦截成功后回调；导航在回调之外执行。
    var onIntercept: ((NavigationRequest) -> Void)?
    /// tap 被系统禁用时回调（参数为累计禁用次数）。
    var onDisabled: ((Int) -> Void)?
    /// 右键事件回调；返回 true 表示该右键已被吞掉（不再显示系统右键菜单）。
    var onRightClick: ((CGPoint) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var suppressVKeyUp = false
    private var disabledCount = 0

    /// ANSI 键盘上的 V 键虚拟键码。
    static let vKeyCode: CGKeyCode = 9

    func start() throws {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, info in
                guard let info else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<SmartPasteEventTap>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw SmartPasteEventTapError.creationFailed
        }

        tap = port

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            throw SmartPasteEventTapError.creationFailed
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        lock.lock()
        suppressVKeyUp = false
        lock.unlock()
    }

    /// tap 是否处于可用状态。
    var isRunning: Bool {
        tap != nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 常驻 tap 一旦被系统禁用，功能会静默失效；必须重新启用并计数。
        if EventTapRecovery.action(for: type) == .reenable {
            EventTapRecovery.reenable(tap)
            lock.lock()
            disabledCount += 1
            let count = disabledCount
            lock.unlock()
            onDisabled?(count)
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // 右键：在文件面板中用于跳转到已复制的目录。
        if type == .rightMouseDown {
            let swallowed = onRightClick?(event.location) == true
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }

        guard keyCode == Self.vKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            lock.lock()
            let shouldSuppress = suppressVKeyUp
            suppressVKeyUp = false
            lock.unlock()
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let alreadySuppressed = suppressVKeyUp
        lock.unlock()
        if alreadySuppressed {
            return nil
        }

        // 只处理纯 ⌘V；叠加其它修饰键时放行。
        let flags = event.flags
        guard flags.contains(.maskCommand),
              !flags.contains(.maskShift),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskControl) else {
            return Unmanaged.passUnretained(event)
        }

        guard let snapshot = resolveSnapshot?(),
              let request = snapshot.request else {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        suppressVKeyUp = true
        lock.unlock()

        // 导航必须在事件回调之外执行。
        DispatchQueue.main.async { [weak self] in
            self?.onIntercept?(request)
        }

        // 吞掉本次 ⌘V，避免路径文本被粘贴进输入框。
        return nil
    }
}
