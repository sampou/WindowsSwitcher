import AppKit
import CoreGraphics
import Foundation

/// 显示器解析协议。
protocol ScreenResolving {
    /// 按窗口位置解析当前显示器。
    func currentScreen(for windowFrame: CGRect) -> ScreenDescriptor?

    /// 按稳定空间顺序解析相邻显示器；首尾循环。
    func adjacentScreen(
        from displayID: CGDirectDisplayID,
        direction: DisplayTraversalDirection
    ) -> ScreenDescriptor?
}

/// 集中处理 NSScreen、Accessibility 坐标转换和稳定显示器顺序。
struct ScreenResolver: ScreenResolving {
    private let screens: [ScreenDescriptor]

    init(screens: [ScreenDescriptor]) {
        self.screens = screens
    }

    /// 从当前系统显示器快照构造解析器。
    init(systemScreens: [NSScreen] = NSScreen.screens, mainScreen: NSScreen? = NSScreen.main) {
        guard let primaryScreen = Self.primaryScreen(from: systemScreens) else {
            screens = []
            return
        }

        let mainDisplayID = mainScreen.flatMap(Self.displayID(for:)) ?? Self.displayID(for: primaryScreen)
        screens = systemScreens.compactMap { screen in
            guard let displayID = Self.displayID(for: screen) else { return nil }
            return ScreenDescriptor(
                id: displayID,
                frame: Self.accessibilityFrame(
                    fromAppKit: screen.frame,
                    primaryScreenFrame: primaryScreen.frame
                ),
                visibleFrame: Self.accessibilityFrame(
                    fromAppKit: screen.visibleFrame,
                    primaryScreenFrame: primaryScreen.frame
                ),
                isMain: displayID == mainDisplayID
            )
        }
    }

    func currentScreen(for windowFrame: CGRect) -> ScreenDescriptor? {
        guard !screens.isEmpty else { return nil }
        let window = windowFrame.standardized
        let ordered = spatiallyOrderedScreens()

        let centerCandidates = ordered.filter { $0.frame.contains(window.center) }
        if let centerMatch = bestIntersectionMatch(for: window, among: centerCandidates) {
            return centerMatch
        }

        if let intersectionMatch = bestIntersectionMatch(for: window, among: ordered),
           intersectionArea(window, intersectionMatch.frame) > 0 {
            return intersectionMatch
        }

        return ordered.first(where: \.isMain) ?? ordered.first
    }

    func adjacentScreen(
        from displayID: CGDirectDisplayID,
        direction: DisplayTraversalDirection
    ) -> ScreenDescriptor? {
        let ordered = spatiallyOrderedScreens()
        guard ordered.count > 1,
              let currentIndex = ordered.firstIndex(where: { $0.id == displayID }) else {
            return nil
        }

        switch direction {
        case .previous:
            return ordered[(currentIndex - 1 + ordered.count) % ordered.count]
        case .next:
            return ordered[(currentIndex + 1) % ordered.count]
        }
    }

    /// AppKit 左下原点矩形转换为 Accessibility 左上原点全局矩形。
    static func accessibilityFrame(fromAppKit frame: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        let frame = frame.standardized
        return CGRect(
            x: frame.minX,
            y: primaryScreenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Accessibility 左上原点矩形转换为 AppKit 左下原点全局矩形。
    static func appKitFrame(fromAccessibility frame: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        let frame = frame.standardized
        return CGRect(
            x: frame.minX,
            y: primaryScreenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func spatiallyOrderedScreens() -> [ScreenDescriptor] {
        screens.sorted { lhs, rhs in
            if lhs.frame.midX != rhs.frame.midX { return lhs.frame.midX < rhs.frame.midX }
            if lhs.frame.midY != rhs.frame.midY { return lhs.frame.midY < rhs.frame.midY }
            return lhs.id < rhs.id
        }
    }

    private func bestIntersectionMatch(
        for windowFrame: CGRect,
        among candidates: [ScreenDescriptor]
    ) -> ScreenDescriptor? {
        candidates.max { lhs, rhs in
            let lhsArea = intersectionArea(windowFrame, lhs.frame)
            let rhsArea = intersectionArea(windowFrame, rhs.frame)
            if lhsArea != rhsArea { return lhsArea < rhsArea }

            let lhsIndex = spatiallyOrderedScreens().firstIndex(where: { $0.id == lhs.id }) ?? .max
            let rhsIndex = spatiallyOrderedScreens().firstIndex(where: { $0.id == rhs.id }) ?? .max
            return lhsIndex > rhsIndex
        }
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func primaryScreen(from screens: [NSScreen]) -> NSScreen? {
        screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
