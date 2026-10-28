import Foundation
import AppKit

/// 剪贴板内容的路径解析结果。
///
/// 解析器只读取剪贴板，不做任何写入，保证原始数据保持不变。
enum ClipboardPathResult: Equatable {
    /// 剪贴板内容是一个存在的目录，可用于智能跳转。
    case directory(URL)
    /// 剪贴板内容是一个存在的文件；按需求不跳转到其父目录，正常粘贴。
    case file(URL)
    /// 路径格式合法但当前无法确认其存在（不存在、无权限、网络卷不可达等）。
    case missing(String)
    /// 剪贴板内容格式无法判定为路径。
    case notApplicable

    /// 仅当内容是目录时才返回目标目录。
    var directoryURL: URL? {
        if case .directory(let url) = self { return url }
        return nil
    }
}

/// 剪贴板路径解析器。
///
/// 规则：
/// - 剪贴板必须只有一个对象，多选目录时不做猜测；
/// - 优先读取 Finder 复制的文件 URL，其次解析纯文本路径；
/// - 只接受绝对路径、`~/` 路径与 `file://` URL，不接受相对路径；
/// - 不自动跳转到文件的父目录；
/// - 不修改剪贴板。
struct ClipboardPathParser {

    func parse(_ pasteboard: NSPasteboard = .general) -> ClipboardPathResult {
        guard let items = pasteboard.pasteboardItems, items.count == 1 else {
            return .notApplicable
        }

        // 优先识别 Finder 复制的文件 URL。
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        if objects.count == 1, let url = objects.first {
            return classify(url)
        }
        if objects.count > 1 {
            return .notApplicable
        }

        guard let text = pasteboard.string(forType: .string) else {
            return .notApplicable
        }

        return parsePathText(text)
    }

    /// 解析纯文本路径。独立为纯函数以便单元测试。
    func parsePathText(_ text: String) -> ClipboardPathResult {
        // 只去掉结尾换行；文本中出现换行说明是多行内容，不作为路径处理。
        let raw = text.trimmingCharacters(in: .newlines)
        guard !raw.isEmpty, !raw.contains("\n"), !raw.contains("\r") else {
            return .notApplicable
        }

        let url: URL

        if raw.hasPrefix("file://") {
            guard let parsed = URL(string: raw), parsed.isFileURL else {
                return .notApplicable
            }
            // 只接受本机文件 URL；带远端主机名的地址（网络卷）不做处理。
            if let host = parsed.host, !host.isEmpty, host != "localhost" {
                return .notApplicable
            }
            url = parsed
        } else {
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                return .notApplicable
            }
            url = URL(fileURLWithPath: path, isDirectory: true)
        }

        return classify(url)
    }

    /// 判断目标是否是可用的目录。
    private func classify(_ url: URL) -> ClipboardPathResult {
        guard url.isFileURL else {
            return .notApplicable
        }

        let normalized = url.standardizedFileURL

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: normalized.path,
            isDirectory: &isDirectory
        )

        guard exists else {
            return .missing(normalized.path)
        }

        guard isDirectory.boolValue else {
            return .file(normalized)
        }

        return .directory(normalized)
    }
}
