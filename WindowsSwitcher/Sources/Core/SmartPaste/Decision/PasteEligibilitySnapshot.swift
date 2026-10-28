import Foundation

/// 一次导航请求的不可变描述。
struct NavigationRequest: Equatable {
    let directory: URL
    let processID: pid_t
    let bundleID: String
    /// 构造请求时的焦点代数；导航过程中代数变化即视为请求失效。
    let focusGeneration: UInt64
    /// 构造请求时的剪贴板版本；导航过程中版本变化即视为请求失效。
    let clipboardChangeCount: Int
}

/// 拦截决策快照。
///
/// Event Tap 回调中只允许读取本结构，不得执行 AX 查询、文件系统访问或剪贴板读取。
struct PasteEligibilitySnapshot: Equatable {

    /// 快照有效期。超过即视为过期，回调中放行原始 ⌘V。
    static let lifetime: TimeInterval = 2.0

    /// 非 nil 表示允许拦截，并携带导航请求。
    let request: NavigationRequest?
    /// 生成快照时的前台进程。
    let processID: pid_t
    /// 生成快照时的焦点代数。
    let focusGeneration: UInt64
    /// 生成快照时的剪贴板版本。
    let clipboardChangeCount: Int
    let createdAt: Date
    let expiresAt: Date

    init(request: NavigationRequest?,
         processID: pid_t,
         focusGeneration: UInt64,
         clipboardChangeCount: Int,
         createdAt: Date = Date(),
         lifetime: TimeInterval = PasteEligibilitySnapshot.lifetime) {
        self.request = request
        self.processID = processID
        self.focusGeneration = focusGeneration
        self.clipboardChangeCount = clipboardChangeCount
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(lifetime)
    }

    /// 空快照：明确不拦截。
    static func empty(processID: pid_t = 0,
                      focusGeneration: UInt64 = 0,
                      clipboardChangeCount: Int = 0) -> PasteEligibilitySnapshot {
        PasteEligibilitySnapshot(request: nil,
                                 processID: processID,
                                 focusGeneration: focusGeneration,
                                 clipboardChangeCount: clipboardChangeCount,
                                 lifetime: 0)
    }

    /// 快照是否仍然有效。
    ///
    /// 有效期只是兜底；真正的正确性由进程、焦点代数与剪贴板版本共同保证。
    func isValid(now: Date = Date(),
                 frontmostProcessID: pid_t?,
                 currentClipboardChangeCount: Int,
                 currentFocusGeneration: UInt64) -> Bool {
        guard let request else { return false }
        guard now < expiresAt else { return false }
        guard let frontmostProcessID, frontmostProcessID == processID else { return false }
        guard frontmostProcessID == request.processID else { return false }
        guard currentClipboardChangeCount == clipboardChangeCount else { return false }
        guard currentFocusGeneration == focusGeneration else { return false }
        return true
    }
}
