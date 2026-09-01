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

// MARK: - Search normalization and fuzzy match

private func normalizeSearchText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
}

private func fuzzyMatch(_ normalizedQuery: String, in text: String) -> Bool {
    guard !normalizedQuery.isEmpty else { return true }
    let normalizedText = normalizeSearchText(text)
    if normalizedText.contains(normalizedQuery) { return true }
    // character-subsequence fuzzy
    var queryIndex = normalizedQuery.startIndex
    for character in normalizedText {
        guard queryIndex < normalizedQuery.endIndex else { return true }
        if character == normalizedQuery[queryIndex] {
            queryIndex = normalizedQuery.index(after: queryIndex)
            if queryIndex == normalizedQuery.endIndex { return true }
        }
    }
    return false
}

// MARK: - FilterCriteria

struct FilterCriteria {
    var searchText: String = ""
    var showOffScreen: Bool = false  // 显示最小化/隐藏的窗口
    /// Exact app name filter (T-033)
    var appName: String? = nil
    /// Filter to current desktop space when true (T-035)
    var currentSpaceOnly: Bool = false
}

// MARK: - FilterEngine

class FilterEngine {

    private let ordering = WindowOrdering()

    func filter(_ windows: [WindowModel], by criteria: FilterCriteria) -> [WindowModel] {
        // Space filter: fetch once, degrade gracefully if API unavailable
        let spaceWindowIDs: Set<CGWindowID>? = criteria.currentSpaceOnly
            ? SpaceAPI.windowIDsOnCurrentSpace()
            : nil
        let normalizedQuery = normalizeSearchText(criteria.searchText)

        return windows.filter { window in
            if !criteria.showOffScreen && (window.isMinimized || window.isHidden) { return false }

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
            if !normalizedQuery.isEmpty {
                return matchScore(query: normalizedQuery, window: window) != nil
            }

            return true
        }
    }

    // T-036: multi-criteria sort
    func sort(_ windows: [WindowModel], by order: SortOrder) -> [WindowModel] {
        ordering.sort(windows, by: order)
    }

    // 应用分组排序：将最活跃应用的窗口排前面
    func sortByAppGroup(_ windows: [WindowModel], targetAppBundleID: String?) -> [WindowModel] {
        ordering.sortByAppGroup(windows, targetAppBundleID: targetAppBundleID)
    }

    // 带目标应用的应用分组排序
    func sortByAppGroupWithTarget(_ windows: [WindowModel], targetAppBundleID: String) -> [WindowModel] {
        ordering.sortByAppGroup(windows, targetAppBundleID: targetAppBundleID)
    }

    func filterAndSort(_ windows: [WindowModel], criteria: FilterCriteria, order: SortOrder) -> [WindowModel] {
        filterAndSort(windows, criteria: criteria, order: order, activitySequence: [:])
    }

    func filterAndSort(
        _ windows: [WindowModel],
        criteria: FilterCriteria,
        order: SortOrder,
        activitySequence: [CGWindowID: UInt64]
    ) -> [WindowModel] {
        let filtered = filter(windows, by: criteria)
        let normalizedQuery = normalizeSearchText(criteria.searchText)
        guard !normalizedQuery.isEmpty else {
            return ordering.sort(filtered, by: order, activitySequence: activitySequence)
        }

        let fallbackOrder = ordering.sort(filtered, by: order, activitySequence: activitySequence)
        let fallbackRank = Dictionary(uniqueKeysWithValues: fallbackOrder.enumerated().map { ($0.element.id, $0.offset) })

        return filtered.sorted { lhs, rhs in
            let lhsScore = matchScore(query: normalizedQuery, window: lhs) ?? 0
            let rhsScore = matchScore(query: normalizedQuery, window: rhs) ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return (fallbackRank[lhs.id] ?? .max) < (fallbackRank[rhs.id] ?? .max)
        }
    }

    private func matchScore(query: String, window: WindowModel) -> Int? {
        let appName = normalizeSearchText(window.appName)
        let windowTitle = normalizeSearchText(window.windowTitle)
        let bundleIdentifier = normalizeSearchText(window.bundleIdentifier)

        if appName == query { return 600 }
        if appName.hasPrefix(query) { return 500 }
        if windowTitle == query { return 450 }
        if windowTitle.hasPrefix(query) { return 400 }
        if appName.contains(query) || windowTitle.contains(query) { return 300 }
        if bundleIdentifier == query { return 250 }
        if bundleIdentifier.hasPrefix(query) { return 225 }
        if bundleIdentifier.contains(query) { return 200 }
        if fuzzyMatch(query, in: window.appName)
            || fuzzyMatch(query, in: window.windowTitle)
            || fuzzyMatch(query, in: window.bundleIdentifier) {
            return 100
        }
        return nil
    }
}
