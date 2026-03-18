import Foundation

struct FilterCriteria {
    var searchText: String = ""
    var showMinimized: Bool = true
    var showHidden: Bool = false
    var appName: String? = nil
}

class FilterEngine {
    func filter(_ windows: [WindowModel], by criteria: FilterCriteria) -> [WindowModel] {
        windows.filter { window in
            if !criteria.showMinimized && window.isMinimized { return false }
            if !criteria.showHidden && window.isHidden { return false }
            if let appName = criteria.appName, window.appName != appName { return false }
            if !criteria.searchText.isEmpty {
                let query = criteria.searchText.lowercased()
                return window.appName.lowercased().contains(query)
                    || window.windowTitle.lowercased().contains(query)
            }
            return true
        }
    }

    func sort(_ windows: [WindowModel], by order: SortOrder) -> [WindowModel] {
        switch order {
        case .recent:      return windows.sorted { $0.lastActiveTime > $1.lastActiveTime }
        case .appName:     return windows.sorted { $0.appName < $1.appName }
        case .windowTitle: return windows.sorted { $0.windowTitle < $1.windowTitle }
        }
    }
}
