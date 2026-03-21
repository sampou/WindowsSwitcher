import Foundation
import AppKit

// MARK: - NSImage helpers
extension NSImage {
    func resized(to size: CGSize) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: size),
             from: NSRect(origin: .zero, size: self.size),
             operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }
}

// MARK: - String fuzzy match
extension String {
    /// BUG-012: 原实现只做 contains，与 FilterEngine 的字符序列匹配不一致
    /// 改为与 FilterEngine.fuzzyMatch 相同的逻辑：子串优先，降级字符序列
    func fuzzyMatch(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        let t = self.lowercased()
        if t.contains(q) { return true }
        var qi = q.startIndex
        for ch in t {
            guard qi < q.endIndex else { return true }
            if ch == q[qi] { qi = q.index(after: qi) }
        }
        return qi == q.endIndex
    }
}

// MARK: - Notification names
extension Notification.Name {
    static let switchHotKeyPressed = Notification.Name("com.windowsswitcher.switchHotKey")
    static let reverseSwitchHotKeyPressed = Notification.Name("com.windowsswitcher.reverseSwitchHotKey")
    static let appSwitchHotKeyPressed = Notification.Name("com.windowsswitcher.appSwitchHotKey")
    static let windowListDidChange = Notification.Name("com.windowsswitcher.windowListDidChange")
}
