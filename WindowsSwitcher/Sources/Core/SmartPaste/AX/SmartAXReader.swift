import Foundation
import ApplicationServices

/// 辅助功能元素的通用安全读取封装。
///
/// 取值风格与 `Core/WindowLayout/AccessibilityWindowBackend` 保持一致：
/// 所有强制转换前都先做类型检查，读取失败一律返回 nil 而不是崩溃。
enum SmartAXReader {

    /// 读取原始属性值。
    static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    /// 读取字符串属性。
    static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    /// 读取角色。
    static func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as CFString)
    }

    /// 读取子角色。
    static func subrole(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXSubroleAttribute as CFString)
    }

    /// 读取标题。
    static func title(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXTitleAttribute as CFString)
    }

    /// 读取子元素。
    static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute as CFString),
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// 读取元素类型的属性。
    ///
    /// AXUIElement 是 CoreFoundation 类型，条件转换恒成功，因此这里先判空再做强制转换。
    static func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name) else {
            return nil
        }
        // AXUIElement 是 CoreFoundation 类型：条件转换恒成功，强制转换会被编译器告警，
        // 因此这里直接做指针级别的位转换（两侧都是单字长引用类型）。
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// 读取元素自身的值（文本框内容等）。
    static func value(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXValueAttribute as CFString)
    }

    /// 读取元素位置。
    static func position(of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute as CFString),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    /// 读取元素尺寸。
    static func size(of element: AXUIElement) -> CGSize? {
        guard let value = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return size
    }

    /// 读取元素所在矩形。
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = position(of: element), let size = size(of: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// 读取文档路径（文件面板当前目录）。
    static func document(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXDocumentAttribute as CFString)
    }

    /// 属性是否可写。
    static func isSettable(_ element: AXUIElement, _ name: CFString) -> Bool {
        var isSettable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, name, &isSettable)
        return error == .success && isSettable.boolValue
    }

    /// 写入文本值。
    @discardableResult
    static func setValue(_ text: String, on element: AXUIElement) -> AXError {
        let value = text as CFString
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value)
    }

    /// 让元素获得键盘焦点。
    ///
    /// 写完路径后必须先聚焦再发 Return：部分应用（Notepad Next）只在路径框
    /// 持有 AX 焦点时才响应回车，否则写入成功但界面毫无反应。
    @discardableResult
    static func setFocused(_ element: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
    }

    /// 触发动作（如按下按钮）。
    @discardableResult
    static func performAction(_ action: String, on element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    /// 当前获得焦点的元素。
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return elementAttribute(system, kAXFocusedUIElementAttribute as CFString)
    }

    /// 当前获得焦点的窗口。
    static func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return elementAttribute(system, kAXFocusedWindowAttribute as CFString)
    }

    /// 指定应用的窗口列表。
    static func windows(ofApplication pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return children(of: app).filter { element in
            subrole(of: element) == (kAXStandardWindowSubrole as String)
        }
    }

    /// 在元素树中广度优先查找第一个满足条件的元素。
    ///
    /// 限制深度与子元素数量，避免在结构复杂的第三方窗口中耗时过长。
    static func firstDescendant(of element: AXUIElement,
                                maxDepth: Int = 6,
                                maxChildrenPerNode: Int = 80,
                                where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]

        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            if predicate(current) {
                return current
            }
            guard depth < maxDepth else { continue }

            let children = children(of: current)
            for child in children.prefix(maxChildrenPerNode) {
                queue.append((child, depth + 1))
            }
        }

        return nil
    }
}
