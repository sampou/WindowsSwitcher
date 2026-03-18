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

            // T-034: fuzzy search on app name + window title
            if !criteria.searchText.isEmpty {
                return fuzzyMatch(criteria.searchText, in: window.appName)
                    || fuzzyMatch(criteria.searchText, in: window.windowTitle)
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
        }
    }

    func filterAndSort(_ windows: [WindowModel], criteria: FilterCriteria, order: SortOrder) -> [WindowModel] {
        sort(filter(windows, by: criteria), by: order)
    }
}
