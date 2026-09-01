import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindowID(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// 封装 AXUIElement，避免测试替身依赖真实系统元素。
final class AccessibilityWindowReference {
    fileprivate let rawElement: AXUIElement?

    init(rawElement: AXUIElement? = nil) {
        self.rawElement = rawElement
    }
}

/// 可写 Accessibility 属性。
enum AccessibilityWritableAttribute: Equatable {
    case position
    case size
}

/// Accessibility 系统访问抽象。
///
/// 生产实现封装 C API；测试通过替身验证能力探测、写入顺序和失败隔离。
protocol AccessibilityWindowAccessing {
    func isProcessTrusted() -> Bool
    func resolveWindow(for model: WindowModel) -> AccessibilityWindowReference?
    func isStandardWindow(_ window: AccessibilityWindowReference) -> Bool
    func isFullScreen(_ window: AccessibilityWindowReference) -> Bool
    func isSettable(
        _ attribute: AccessibilityWritableAttribute,
        for window: AccessibilityWindowReference
    ) -> Bool
    func frame(of window: AccessibilityWindowReference) -> CGRect?
    func setPosition(_ position: CGPoint, for window: AccessibilityWindowReference) -> AXError
    func setSize(_ size: CGSize, for window: AccessibilityWindowReference) -> AXError
}

/// 基于 macOS Accessibility API 的生产访问实现。
struct SystemAccessibilityWindowBackend: AccessibilityWindowAccessing {
    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func resolveWindow(for model: WindowModel) -> AccessibilityWindowReference? {
        let app = AXUIElementCreateApplication(model.ownerPID)
        var windowList: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &windowList
        ) == .success,
        let windows = windowList as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            var windowID: CGWindowID = 0
            if AXUIElementGetWindowID(window, &windowID) == .success, windowID == model.id {
                return AccessibilityWindowReference(rawElement: window)
            }
        }

        // 私有 ID 查询不可用时，只允许“frame + 标题”联合匹配；禁止仅按标题选择，避免操作错误窗口。
        for window in windows {
            let reference = AccessibilityWindowReference(rawElement: window)
            guard let frame = frame(of: reference) else {
                continue
            }

            let title = stringAttribute(kAXTitleAttribute as CFString, of: window)
            if Self.matchesFallback(
                modelFrame: model.frame,
                modelTitle: model.windowTitle,
                candidateFrame: frame,
                candidateTitle: title
            ) {
                return reference
            }
        }

        return nil
    }

    /// ID 不可用时的保守匹配规则；标题缺失时宁可不匹配，也不仅依赖 frame 猜测。
    static func matchesFallback(
        modelFrame: CGRect,
        modelTitle: String,
        candidateFrame: CGRect,
        candidateTitle: String?
    ) -> Bool {
        guard !modelTitle.isEmpty, candidateTitle == modelTitle else {
            return false
        }
        return candidateFrame.isApproximatelyEqual(to: modelFrame, tolerance: 5)
    }

    func isStandardWindow(_ window: AccessibilityWindowReference) -> Bool {
        guard let element = window.rawElement,
              stringAttribute(kAXRoleAttribute as CFString, of: element) == (kAXWindowRole as String) else {
            return false
        }

        // 部分应用不提供 subrole；有值时必须是标准窗口，避免调整面板、弹出层和系统对话框。
        guard let subrole = stringAttribute(kAXSubroleAttribute as CFString, of: element) else {
            return true
        }
        return subrole == (kAXStandardWindowSubrole as String)
    }

    func isFullScreen(_ window: AccessibilityWindowReference) -> Bool {
        guard let element = window.rawElement else { return false }
        var value: CFTypeRef?
        let attribute = "AXFullScreen" as CFString
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }

    func isSettable(
        _ attribute: AccessibilityWritableAttribute,
        for window: AccessibilityWindowReference
    ) -> Bool {
        guard let element = window.rawElement else { return false }
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute.axName, &settable)
        return result == .success && settable.boolValue
    }

    func frame(of window: AccessibilityWindowReference) -> CGRect? {
        guard let element = window.rawElement,
              let position = pointAttribute(kAXPositionAttribute as CFString, of: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, of: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    func setPosition(_ position: CGPoint, for window: AccessibilityWindowReference) -> AXError {
        guard let element = window.rawElement else { return .invalidUIElement }
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func setSize(_ size: CGSize, for window: AccessibilityWindowReference) -> AXError {
        guard let element = window.rawElement else { return .invalidUIElement }
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func pointAttribute(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return size
    }
}

private extension AccessibilityWritableAttribute {
    var axName: CFString {
        switch self {
        case .position:
            return kAXPositionAttribute as CFString
        case .size:
            return kAXSizeAttribute as CFString
        }
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
