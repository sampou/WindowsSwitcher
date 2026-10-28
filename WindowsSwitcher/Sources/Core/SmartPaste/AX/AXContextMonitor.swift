import Foundation
import AppKit
import ApplicationServices

/// 前台应用与焦点变化监控。
///
/// 只负责「发生了什么变化」，不负责判定；判定逻辑在 `SmartPasteCoordinator`。
/// 所有辅助功能读取都在调用方指定的队列上完成，避免占用主线程。
final class AXContextMonitor {

    /// 当前上下文快照。
    struct Context {
        var processID: pid_t?
        var bundleID: String?
        var focusedWindow: AXUIElement?
        var focusedElement: AXUIElement?
        var focusedRole: String?
        var focusedSubrole: String?
        var focusedValue: String?
        var clipboardChangeCount: Int
    }

    /// 上下文发生变化时回调（在前台应用切换、焦点变化、剪贴板变化时触发）。
    var onChange: (() -> Void)?

    private let queue: DispatchQueue
    private var observer: AXObserver?
    private var observedProcessID: pid_t?
    private var workspaceToken: NSObjectProtocol?
    private var clipboardTimer: DispatchSourceTimer?
    private var lastClipboardChangeCount: Int = -1

    /// 前台应用信息缓存：只在前台应用切换通知（主线程）中更新。
    private let lock = NSLock()
    private var cachedProcessID: pid_t?
    private var cachedBundleID: String?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        guard workspaceToken == nil else { return }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceToken = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.handleApplicationActivation(app)
        }

        // 启动时先缓存一次前台应用。
        updateFrontmostApplication(NSWorkspace.shared.frontmostApplication)
        observeApplication(processID: cachedProcessID)

        startClipboardPolling()
    }

    func stop() {
        if let token = workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceToken = nil
        }
        clipboardTimer?.cancel()
        clipboardTimer = nil
        removeObserver()

        lock.lock()
        cachedProcessID = nil
        cachedBundleID = nil
        lock.unlock()
    }

    /// 读取当前上下文。必须在 `queue` 上调用（内部执行辅助功能查询）。
    func currentContext() -> Context {
        lock.lock()
        let processID = cachedProcessID
        let bundleID = cachedBundleID
        lock.unlock()

        var focusedWindow: AXUIElement?
        var focusedElement: AXUIElement?

        if let processID {
            let app = AXUIElementCreateApplication(processID)
            focusedWindow = SmartAXReader.elementAttribute(app, kAXFocusedWindowAttribute as CFString)
            focusedElement = SmartAXReader.elementAttribute(app, kAXFocusedUIElementAttribute as CFString)
        }

        return Context(
            processID: processID,
            bundleID: bundleID,
            focusedWindow: focusedWindow,
            focusedElement: focusedElement,
            focusedRole: focusedElement.flatMap { SmartAXReader.role(of: $0) },
            focusedSubrole: focusedElement.flatMap { SmartAXReader.subrole(of: $0) },
            focusedValue: focusedElement.flatMap { SmartAXReader.value(of: $0) },
            clipboardChangeCount: NSPasteboard.general.changeCount
        )
    }

    // MARK: - 内部

    private func handleApplicationActivation(_ app: NSRunningApplication?) {
        updateFrontmostApplication(app)
        observeApplication(processID: cachedProcessID)
        notifyChange()
    }

    private func updateFrontmostApplication(_ app: NSRunningApplication?) {
        lock.lock()
        cachedProcessID = app?.processIdentifier
        cachedBundleID = app?.bundleIdentifier
        lock.unlock()
    }

    private func observeApplication(processID: pid_t?) {
        guard let processID else {
            removeObserver()
            return
        }
        guard observedProcessID != processID else { return }

        removeObserver()

        let app = AXUIElementCreateApplication(processID)
        var newObserver: AXObserver?
        let error = AXObserverCreate(processID, { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AXContextMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.notifyChange()
        }, &newObserver)

        guard error == .success, let newObserver else {
            return
        }

        AXObserverAddNotification(newObserver,
                                  app,
                                  kAXFocusedUIElementChangedNotification as CFString,
                                  nil)
        AXObserverAddNotification(newObserver,
                                  app,
                                  kAXFocusedWindowChangedNotification as CFString,
                                  nil)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)

        observer = newObserver
        observedProcessID = processID
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            self.observer = nil
        }
        observedProcessID = nil
    }

    private func startClipboardPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(300), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let count = NSPasteboard.general.changeCount
            guard count != self.lastClipboardChangeCount else { return }
            self.lastClipboardChangeCount = count
            self.notifyChange()
        }
        timer.resume()
        clipboardTimer = timer
    }

    private func notifyChange() {
        let callback = onChange
        guard let callback else { return }
        queue.async {
            callback()
        }
    }
}
