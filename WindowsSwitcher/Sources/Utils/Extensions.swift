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
    func fuzzyMatch(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Notification names
extension Notification.Name {
    static let switchHotKeyPressed = Notification.Name("com.windowsswitcher.switchHotKey")
    static let reverseSwitchHotKeyPressed = Notification.Name("com.windowsswitcher.reverseSwitchHotKey")
    static let appSwitchHotKeyPressed = Notification.Name("com.windowsswitcher.appSwitchHotKey")
    static let windowListDidChange = Notification.Name("com.windowsswitcher.windowListDidChange")
}
