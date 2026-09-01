import CoreGraphics
import Foundation

/// 窗口排序的唯一规则入口。
///
/// 所有比较都以窗口 ID 降序作为最终兜底，保证相同输入始终得到相同顺序。
struct WindowOrdering {
    func sort(
        _ windows: [WindowModel],
        by order: SortOrder,
        activitySequence: [CGWindowID: UInt64] = [:]
    ) -> [WindowModel] {
        switch order {
        case .recent:
            return windows.sorted { recentComesBefore($0, $1, activitySequence: activitySequence) }
        case .appName:
            return windows.sorted { appNameComesBefore($0, $1) }
        case .windowTitle:
            return windows.sorted { windowTitleComesBefore($0, $1) }
        case .appGroup:
            return sortByAppGroup(
                windows,
                targetAppBundleID: nil,
                activitySequence: activitySequence
            )
        }
    }

    func sortByAppGroup(
        _ windows: [WindowModel],
        targetAppBundleID: String?,
        activitySequence: [CGWindowID: UInt64] = [:]
    ) -> [WindowModel] {
        if let targetAppBundleID {
            let target = windows.filter { $0.bundleIdentifier == targetAppBundleID }
            let others = windows.filter { $0.bundleIdentifier != targetAppBundleID }
            return sort(target, by: .recent, activitySequence: activitySequence)
                + sort(others, by: .recent, activitySequence: activitySequence)
        }

        let groups = Dictionary(grouping: windows, by: \.bundleIdentifier)
        let sortedBundleIDs = groups.keys.sorted { lhs, rhs in
            let lhsWindows = groups[lhs] ?? []
            let rhsWindows = groups[rhs] ?? []
            guard let lhsFirst = sort(lhsWindows, by: .recent, activitySequence: activitySequence).first,
                  let rhsFirst = sort(rhsWindows, by: .recent, activitySequence: activitySequence).first else {
                return lhs < rhs
            }

            if recentComesBefore(lhsFirst, rhsFirst, activitySequence: activitySequence) { return true }
            if recentComesBefore(rhsFirst, lhsFirst, activitySequence: activitySequence) { return false }

            let appComparison = lhsFirst.appName.localizedCompare(rhsFirst.appName)
            if appComparison != .orderedSame { return appComparison == .orderedAscending }
            if lhs != rhs { return lhs < rhs }
            return lhsFirst.id > rhsFirst.id
        }

        return sortedBundleIDs.flatMap { bundleID in
            sort(groups[bundleID] ?? [], by: .recent, activitySequence: activitySequence)
        }
    }

    private func recentComesBefore(
        _ lhs: WindowModel,
        _ rhs: WindowModel,
        activitySequence: [CGWindowID: UInt64]
    ) -> Bool {
        let lhsSequence = activitySequence[lhs.id] ?? 0
        let rhsSequence = activitySequence[rhs.id] ?? 0
        if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
        if lhs.lastActiveTime != rhs.lastActiveTime { return lhs.lastActiveTime > rhs.lastActiveTime }
        return lhs.id > rhs.id
    }

    private func appNameComesBefore(_ lhs: WindowModel, _ rhs: WindowModel) -> Bool {
        let appComparison = lhs.appName.localizedCompare(rhs.appName)
        if appComparison != .orderedSame { return appComparison == .orderedAscending }

        let bundleComparison = lhs.bundleIdentifier.compare(rhs.bundleIdentifier)
        if bundleComparison != .orderedSame { return bundleComparison == .orderedAscending }

        let titleComparison = lhs.windowTitle.localizedCompare(rhs.windowTitle)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return lhs.id > rhs.id
    }

    private func windowTitleComesBefore(_ lhs: WindowModel, _ rhs: WindowModel) -> Bool {
        let titleComparison = lhs.windowTitle.localizedCompare(rhs.windowTitle)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }

        let appComparison = lhs.appName.localizedCompare(rhs.appName)
        if appComparison != .orderedSame { return appComparison == .orderedAscending }

        let bundleComparison = lhs.bundleIdentifier.compare(rhs.bundleIdentifier)
        if bundleComparison != .orderedSame { return bundleComparison == .orderedAscending }
        return lhs.id > rhs.id
    }
}
