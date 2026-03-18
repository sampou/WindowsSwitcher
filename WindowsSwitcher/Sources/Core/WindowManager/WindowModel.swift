import AppKit
import CoreGraphics

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

    static func == (lhs: WindowModel, rhs: WindowModel) -> Bool {
        lhs.id == rhs.id
    }
}
