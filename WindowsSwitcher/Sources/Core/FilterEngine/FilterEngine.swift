import Foundation
import CoreGraphics

// MARK: - Space filtering (CGSSpace private API with graceful degradation)

private typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopySpaces") private func CGSCopySpaces(_ cid: CGSConnectionID, _ mask: Int) -> CFArray?
@_silgen_name("CGSCopyWindowsWithOptionsAndTags") private func CGSCopyWindowsWithOptionsAndTags(
    _ cid: CGSConnectionID, _ owner: UInt32, _ spaces: CFArray,
    _ options: Int, _ setTags: UnsafeMutablePointer<CFTypeRef?>,
    _ clearTags: UnsafeMutablePointer<CFTypeRef?>) -> CFArray?

private enum SpaceAPI {
    static var available: Bool = {
        // Probe at runtime; symbol may be absent on future OS versions
        let handle = dlopen(nil, RTLD_LAZY)
        let sym = dlsym(handle, "CGSMainConnectionID")
        dlclose(handle)
        return sym != nil
    }()

    /// Returns window IDs on the current active space, or nil if unavailable.
    static func windowIDsOnCurrentSpace() -> Set<CGWindowID>? {
        guard available else { return nil }
        let cid = CGSMainConnectionID()
        // mask 5 = current space
        guard let spaces = CGSCopySpaces(cid, 5) as? [CFTypeRef], !spaces.isEmpty else { return nil }
        var setTags: CFTypeRef? = nil
        var clearTags: CFTypeRef? = nil
        guard let wins = CGSCopyWindowsWithOptionsAndTags(
            cid, 0, spaces as CFArray, 2, &setTags, &clearTags) as? [CGWindowID]
        else { return nil }
        return Set(wins)
    }
}

// MARK: - Fuzzy match

private func fuzzyMatch(_ query: String, in text: String) -> Bool {
    guard !query.isEmpty else { return true }
    let q = query.lowercased()
    let t = text.lowercased()
    if t.contains(q) { return true }
    // character-subsequence fuzzy
    var qi = q.startIndex
    for ch in t {
        guard qi < q.endIndex else { return true }
        if ch == q[qi] {
            qi = q.index(after: qi)
            if qi == q.endIndex { return true }
        }
    }
    return false
}

// MARK: - FilterCriteria

struct FilterCriteria {
    var searchText: String = ""
    var showMinimized: Bool = true
    var showHidden: Bool = false
    /// Exact app name filter (T-033)
    var appName: String? = nil
    /// Filter to current desktop space when true (T-035)
    var currentSpaceOnly: Bool = false
}

// MARK: - FilterEngine

class FilterEngine {

    func filter(_ windows: [WindowModel], by criteria: FilterCriteria) -> [WindowModel] {
        // Space filter: fetch once, degrade gracefully if API unavailable
        let spaceWindowIDs: Set<CGWindowID>? = criteria.currentSpaceOnly
            ? SpaceAPI.windowIDsOnCurrentSpace()
            : nil

        return windows.filter { window in
            if !criteria.showMinimized && window.isMinimized { return false }
            if !criteria.showHidden && window.isHidden { return false }

            // T-033: exact app name filter
            if let appName = criteria.appName, window.appName != appName { return false }

            // T-035: space filter with degradation
            if criteria.currentSpaceOnly {
                if let ids = spaceWindowIDs {
                    if !ids.contains(window.id) { return false }
                }
                // if API unavailable, skip space filtering (degraded mode)
            }

            // T-034: fuzzy search on app name + window title + bundle identifier
            if !criteria.searchText.isEmpty {
                return fuzzyMatch(criteria.searchText, in: window.appName)
                    || fuzzyMatch(criteria.searchText, in: window.windowTitle)
                    || fuzzyMatch(criteria.searchText, in: window.bundleIdentifier)
            }

            return true
        }
    }

    // T-036: multi-criteria sort
    func sort(_ windows: [WindowModel], by order: SortOrder) -> [WindowModel] {
        switch order {
        case .recent:      return windows.sorted { $0.lastActiveTime > $1.lastActiveTime }
        case .appName:     return windows.sorted { $0.appName.localizedCompare($1.appName) == .orderedAscending }
        case .windowTitle: return windows.sorted { $0.windowTitle.localizedCompare($1.windowTitle) == .orderedAscending }
        case .appGroup:    return sortByAppGroup(windows, targetAppBundleID: nil)
        }
    }

    /// 按应用程序分组排序
    /// - 参数:
    ///   - windows: 窗口列表
    ///   - targetAppBundleID: 目标应用程序的 bundleIdentifier，如果为 nil 则按最近活跃应用分组
    /// - 返回: 排序后的窗口列表
    ///   排序规则:
    ///   1. 第一个位置显示目标应用的窗口（如果指定了目标应用）
    ///   2. 第二个位置开始显示其他应用的窗口，按最近活跃时间降序排列
    func sortByAppGroup(_ windows: [WindowModel], targetAppBundleID: String?) -> [WindowModel] {
        guard !windows.isEmpty else { return [] }

        // 确定目标应用：如果没有指定，使用最活跃的应用
        let targetApp: String
        if let bundleID = targetAppBundleID {
            targetApp = bundleID
        } else {
            // 找到最近最活跃的应用
            targetApp = windows.max(by: { $0.lastActiveTime < $1.lastActiveTime })?.bundleIdentifier ?? ""
        }

        // 分离目标应用窗口和其他应用窗口
        let targetWindows = windows.filter { $0.bundleIdentifier == targetApp }
        let otherWindows = windows.filter { $0.bundleIdentifier != targetApp }

        // 按活跃时间排序
        let sortedTarget = targetWindows.sorted { $0.lastActiveTime > $1.lastActiveTime }
        let sortedOther = otherWindows.sorted { $0.lastActiveTime > $1.lastActiveTime }

        // 合并：目标应用窗口在前，其他应用窗口按活跃时间在后
        return sortedTarget + sortedOther
    }

    /// 带目标应用的分组排序（用于切换到指定应用后重新排列）
    /// - 参数:
    ///   - windows: 窗口列表
    ///   - targetAppBundleID: 目标应用程序的 bundleIdentifier
    /// - 返回: 排序后的窗口列表
    ///   排序规则:
    ///   1. 第一个位置显示目标应用的窗口（刚切换到的）
    ///   2. 第二个位置显示原最活跃应用中最活跃的窗口
    ///   3. 第三个位置显示原最活跃应用中次级活跃的窗口
    ///   4. 后续位置依次按所有窗口的活跃度降序排列（排除目标应用已显示的窗口）
    func sortByAppGroupWithTarget(_ windows: [WindowModel], targetAppBundleID: String) -> [WindowModel] {
        guard !windows.isEmpty else { return [] }

        // 获取目标应用的窗口
        let targetWindows = windows.filter { $0.bundleIdentifier == targetAppBundleID }
        let otherWindows = windows.filter { $0.bundleIdentifier != targetAppBundleID }

        // 目标应用窗口按活跃时间排序，取最活跃的作为第一个
        let sortedTarget = targetWindows.sorted { $0.lastActiveTime > $1.lastActiveTime }

        // 其他应用窗口按活跃时间排序
        let sortedOther = otherWindows.sorted { $0.lastActiveTime > $1.lastActiveTime }

        // 合并：目标应用窗口 + 其他应用窗口
        return sortedTarget + sortedOther
    }

    func filterAndSort(_ windows: [WindowModel], criteria: FilterCriteria, order: SortOrder) -> [WindowModel] {
        sort(filter(windows, by: criteria), by: order)
    }
}
