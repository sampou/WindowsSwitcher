import AppKit
@testable import WindowsSwitcher

// Keep existing test fixtures readable while supplying fields added to the
// production model.
extension WindowModel {
    init(
        id: CGWindowID,
        appName: String,
        bundleIdentifier: String,
        windowTitle: String,
        appIcon: NSImage,
        frame: CGRect,
        isMinimized: Bool,
        isHidden: Bool,
        isOnScreen: Bool,
        lastActiveTime: Date,
        windowLayer: Int,
        ownerPID: pid_t
    ) {
        self.init(
            id: id,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            appIcon: appIcon,
            frame: frame,
            isMinimized: isMinimized,
            isHidden: isHidden,
            isOnScreen: isOnScreen,
            lastActiveTime: lastActiveTime,
            windowLayer: windowLayer,
            ownerPID: ownerPID,
            isStandardWindow: true
        )
    }
}
