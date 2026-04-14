import SwiftUI
import AppKit
import Combine

// MARK: - DockPreviewManager (Shared Instance)
/// 程序坞预览管理器 - 单例，复用 PreviewGenerator，优化性能
class DockPreviewManager: ObservableObject {
    static let shared = DockPreviewManager()

    @Published var isPreviewVisible: Bool = false
    @Published var previewItems: [DockPreviewItem] = []
    @Published var currentDockPosition: DockPosition = .bottom
    @Published var hoveredIndex: Int?
    @Published var previewImages: [CGWindowID: NSImage] = [:]
    @Published var iconCenter: CGPoint?
    @Published var previewWindowFrame: CGRect = .zero  // 预览窗口的屏幕位置
    @Published var largePreviewItem: DockPreviewItem?  // 悬停时显示的大预览项目
    @Published var largePreviewFrame: CGRect = .zero    // 大预览窗口的 frame
    @Published var isLargePreviewVisible: Bool = false // 大预览窗口是否可见

    let previewGenerator = PreviewGenerator()

    // 大预览窗口尺寸
    var largePreviewWidth: CGFloat = 600
    var largePreviewHeight: CGFloat = 400  // 3:2 比例，更大更清晰

    private let eventMonitor = DockEventMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var mouseCheckTimer: Timer?

    private init() {
        setupBindings()
    }

    func start() {
        eventMonitor.startMonitoring()
    }

    func stop() {
        eventMonitor.stopMonitoring()
        mouseCheckTimer?.invalidate()
        isPreviewVisible = false
    }

    /// 同步获取当前悬停图标的中心位置（用于面板定位）
    func getCurrentIconCenter() -> CGPoint? {
        // 优先使用已设置的 hoveredIconInfo
        if let iconInfo = eventMonitor.hoveredIconInfo {
            Logger.debug("[DockManager] 使用 hoveredIconInfo: \(iconInfo.center)")
            return iconInfo.center
        }
        // 否则通过当前鼠标位置获取
        let mouseLocation = eventMonitor.mouseLocation
        if let iconInfo = eventMonitor.getDockIconInfoAtLocation(mouseLocation) {
            Logger.debug("[DockManager] 通过鼠标位置获取: \(iconInfo.center)")
            return iconInfo.center
        }
        Logger.warning("[DockManager] 无法获取图标位置")
        return nil
    }

    private func setupBindings() {
        // 监听图标位置变化（先更新 iconCenter）
        eventMonitor.$hoveredIconInfo
            .sink { [weak self] iconInfo in
                self?.iconCenter = iconInfo?.center
            }
            .store(in: &cancellables)

        // 监听 Dock 图标悬停（在 iconCenter 更新后再处理）
        eventMonitor.$hoveredAppBundleID
            .removeDuplicates()
            .sink { [weak self] bundleID in
                self?.handleHoverChange(bundleID: bundleID)
            }
            .store(in: &cancellables)

        // 监听 Dock 位置变化
        eventMonitor.$dockPosition
            .assign(to: &$currentDockPosition)

        // 监听鼠标位置变化
        eventMonitor.$mouseLocation
            .sink { [weak self] location in
                self?.checkMouseInPreviewWindow(location)
            }
            .store(in: &cancellables)

        // 监听悬停索引变化，显示/隐藏大预览窗口
        $hoveredIndex
            .sink { [weak self] index in
                self?.handleHoveredIndexChange(index)
            }
            .store(in: &cancellables)
    }

    /// 处理悬停索引变化
    private func handleHoveredIndexChange(_ index: Int?) {
        if let index = index, index < previewItems.count {
            let item = previewItems[index]
            largePreviewItem = item
            calculateLargePreviewPosition(for: item, at: index)
            isLargePreviewVisible = true
        } else {
            isLargePreviewVisible = false
            largePreviewItem = nil
        }
    }

    /// 计算大预览窗口的位置和尺寸 - 按照原窗口尺寸，不缩放
    private func calculateLargePreviewPosition(for item: DockPreviewItem, at index: Int) {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame

        // 获取实际窗口的尺寸，原尺寸展示
        let windowFrame = item.windowModel.frame
        let previewWidth = windowFrame.width
        let previewHeight = windowFrame.height

        // 屏幕完全居中显示
        let x = screenFrame.midX - previewWidth / 2
        let y = screenFrame.midY - previewHeight / 2

        // 确保不超出屏幕边界
        let finalX = max(screenFrame.minX + 10, min(x, screenFrame.maxX - previewWidth - 10))
        let finalY = max(screenFrame.minY + 10, min(y, screenFrame.maxY - previewHeight - 10))

        largePreviewFrame = CGRect(x: finalX, y: finalY, width: previewWidth, height: previewHeight)

        // 更新大预览尺寸
        largePreviewWidth = previewWidth
        largePreviewHeight = previewHeight
    }

    /// 更新预览窗口的 frame（由 AppDelegate 调用）
    func updatePreviewWindowFrame(_ frame: CGRect) {
        previewWindowFrame = frame
    }

    /// 检查鼠标是否在预览窗口内
    private func checkMouseInPreviewWindow(_ location: CGPoint) {
        guard isPreviewVisible else { return }

        // 扩大检测区域，增加 10 像素的容差
        let expandedFrame = previewWindowFrame.insetBy(dx: -10, dy: -10)
        let isInPreview = expandedFrame.contains(location)

        eventMonitor.isMouseInPreviewWindow = isInPreview

        if isInPreview {
            // 鼠标在预览窗口内，保持显示
            mouseCheckTimer?.invalidate()
        } else {
            // 鼠标离开预览窗口，检查是否在 Dock 区域
            let dockFrame = DockGeometry.getDockFrame()
            let isInDockArea = dockFrame.insetBy(dx: -30, dy: -30).contains(location)

            if !isInDockArea {
                // 也不在 Dock 区域，隐藏预览
                eventMonitor.startHideTimer()
            }
        }
    }

    private func handleHoverChange(bundleID: String?) {
        guard let bundleID = bundleID else {
            hidePreview()
            return
        }

        // 强制同步获取图标中心位置（确保定位正确）
        // 优先从 eventMonitor 获取已设置的 hoveredIconInfo
        if let iconInfo = eventMonitor.hoveredIconInfo {
            self.iconCenter = iconInfo.center
        } else {
            // 如果 hoveredIconInfo 为 nil，尝试通过当前鼠标位置重新获取
            let mouseLocation = eventMonitor.mouseLocation
            if let iconInfo = eventMonitor.getDockIconInfoAtLocation(mouseLocation) {
                self.iconCenter = iconInfo.center
            }
        }

        // 强制刷新窗口缓存，确保获取最新的窗口列表
        WindowManager.shared.refreshCache()

        // 获取该应用的所有窗口
        let allWindows = WindowManager.shared.windows
        let matchingWindows = allWindows.filter { $0.bundleIdentifier == bundleID }

        // 放宽过滤条件
        let windows = matchingWindows.filter { !$0.isMinimized }

        guard !windows.isEmpty else {
            hidePreview()
            return
        }

        // 按 lastActiveTime 降序排序，确保最新活跃的窗口在最前面
        // 按窗口 ID 升序排列（最早的窗口排在前面）
        // CGWindowID 是系统按创建顺序分配的，ID 越小表示创建越早
        // 这与 Command+Tab 切换器的 lastActiveTime 降序排序完全独立
        let sortedWindows = windows.sorted { $0.id < $1.id }

        // 创建预览项 - 显示所有窗口，不再限制数量
        previewItems = sortedWindows.map { windowModel in
            var item = DockPreviewItem(windowModel: windowModel)
            item.previewGenerator = previewGenerator
            return item
        }

        // 预加载预览图（在显示之前就开始加载）
        preloadPreviews(for: sortedWindows)

        showPreview()
    }

    // 预加载预览图（实时获取最新内容，不使用缓存）
    private func preloadPreviews(for windows: [WindowModel]) {
        let previewSize = ConfigManager.shared.config.appearance.previewSize.dimensions
        let size = CGSize(width: previewSize.width, height: previewSize.height)

        Task(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for window in windows {
                    group.addTask {
                        // 使用实时预览方法，不使用缓存
                        if let image = await self.previewGenerator.generateRealtimePreview(for: window, size: size) {
                            await MainActor.run {
                                self.previewImages[window.id] = image
                            }
                        }
                    }
                }
            }
        }
    }

    private func showPreview() {
        guard !previewItems.isEmpty else {
            return
        }

        withAnimation(.easeOut(duration: 0.1)) {
            isPreviewVisible = true
        }
    }

    private func hidePreview() {
        withAnimation(.easeIn(duration: 0.08)) {
            isPreviewVisible = false
            hoveredIndex = nil
        }
        // 重置事件监听器状态，确保下次悬停能正常触发
        eventMonitor.resetState()
        // 清空预览图缓存，确保下次获取最新窗口内容
        previewImages.removeAll()
    }

    // 公开方法，供外部调用隐藏预览
    public func hidePreviewPanel() {
        hidePreview()
    }

    func selectItem(_ item: DockPreviewItem) {
        // 激活窗口
        WindowManager.shared.activateWindow(item.windowModel)

        // 延迟隐藏预览（给窗口激活留出时间）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.hidePreview()
        }

        // 通知外部（如 AppDelegate）用户已选择窗口
        NotificationCenter.default.post(
            name: .dockPreviewWindowSelected,
            object: nil,
            userInfo: ["windowModel": item.windowModel]
        )
    }
}

// MARK: - DockPreviewPanelView
/// 程序坞预览面板主视图 - 与切换器面板样式一致
struct DockPreviewPanelView: View {
    @ObservedObject var manager: DockPreviewManager
    @ObservedObject private var configManager = ConfigManager.shared
    let onDismiss: () -> Void

    // 每行最多显示的窗口数量
    private var itemsPerRow: Int {
        configManager.config.dockPreview.maxPreviewCount
    }

    // 使用切换器的预览尺寸配置
    private var previewSize: PreviewSize {
        configManager.config.appearance.previewSize
    }

    private var itemWidth: CGFloat {
        previewSize.itemDimensions.width
    }

    private var itemHeight: CGFloat {
        previewSize.itemDimensions.height
    }

    private var previewWidth: CGFloat {
        previewSize.dimensions.width
    }

    private var previewHeight: CGFloat {
        previewSize.dimensions.height
    }

    // 间距
    private var itemSpacing: CGFloat { 16 }  // 行间距
    private var itemPadding: CGFloat { 8 }   // 窗口项外部 padding
    private var panelPadding: CGFloat { DesignTokens.Panel.padding }

    // 计算总行数
    private var totalRows: Int {
        let count = manager.previewItems.count
        return (count + itemsPerRow - 1) / itemsPerRow
    }

    // 最多显示的行数（超过需要滚动）
    private var maxDisplayRows: Int { 3 }

    // 是否需要显示滚动条（两行及以上才显示）
    private var needsScroll: Bool {
        totalRows >= 2
    }

    // 是否需要滚动功能（内容超出显示区域）
    private var needsScrolling: Bool {
        totalRows > maxDisplayRows
    }

    var body: some View {
        VStack(spacing: 8) {
            // 滚动区域
            ScrollView(.vertical, showsIndicators: needsScroll) {
                VStack(spacing: itemSpacing) {
                    // 按行显示窗口
                    ForEach(0..<totalRows, id: \.self) { rowIndex in
                        rowView(for: rowIndex)
                            .frame(height: itemHeight + itemPadding * 2)
                    }
                }
                .padding(.horizontal, panelPadding)
                .padding(.vertical, panelPadding)
            }
            .frame(maxHeight: contentHeight)

            // 滚动提示（仅当内容超出显示区域时显示）
            if needsScrolling {
                scrollIndicator
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .frame(width: panelWidth, height: totalPanelHeight)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Panel.cornerRadius))
        .shadow(
            color: .black.opacity(0.25),
            radius: DesignTokens.Panel.shadowRadius,
            x: 0,
            y: DesignTokens.Panel.shadowY
        )
        .animation(.easeInOut(duration: 0.2), value: totalRows)
    }

    // 每行视图
    @ViewBuilder
    private func rowView(for rowIndex: Int) -> some View {
        let startIndex = rowIndex * itemsPerRow
        let endIndex = min(startIndex + itemsPerRow, manager.previewItems.count)
        let rowItems = Array(manager.previewItems[startIndex..<endIndex])

        HStack(spacing: 0) {
            ForEach(Array(rowItems.enumerated()), id: \.element.id) { index, item in
                let globalIndex = startIndex + index
                DockPreviewItemView(
                    item: item,
                    isHovered: manager.hoveredIndex == globalIndex,
                    previewWidth: previewWidth,
                    previewHeight: previewHeight,
                    itemWidth: itemWidth,
                    itemHeight: itemHeight,
                    cachedImage: manager.previewImages[item.id],
                    onTap: {
                        manager.selectItem(item)
                    },
                    onHover: { isHovered in
                        manager.hoveredIndex = isHovered ? globalIndex : nil
                    }
                )
                .padding(itemPadding)
            }
        }
    }

    // 面板宽度（自适应，基于实际窗口数量）
    private var panelWidth: CGFloat {
        // 窗口项实际宽度 = itemWidth + 左右 padding
        let actualItemWidth = itemWidth + itemPadding * 2
        // 第一行实际显示的窗口数（不超过 itemsPerRow）
        let firstRowCount = min(manager.previewItems.count, itemsPerRow)
        return CGFloat(firstRowCount) * actualItemWidth + panelPadding * 2
    }

    // 内容高度（每行高度 = itemHeight + 上下 padding）
    private var contentHeight: CGFloat {
        let actualRowHeight = itemHeight + itemPadding * 2
        if needsScrolling {
            // 内容超出显示区域时，显示固定高度（允许滚动）
            return CGFloat(maxDisplayRows) * actualRowHeight + CGFloat(maxDisplayRows - 1) * itemSpacing
        } else {
            // 不需要滚动时，显示实际内容高度
            return CGFloat(totalRows) * actualRowHeight + CGFloat(totalRows - 1) * itemSpacing
        }
    }

    // 总面板高度
    private var totalPanelHeight: CGFloat {
        var height = contentHeight + panelPadding * 2 // 上下 padding
        if needsScrolling {
            height += 32 // 滚动提示高度
        }
        return height
    }

    // 滚动提示
    private var scrollIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.up")
                .font(.system(size: 10))
                .opacity(0.5)
            Text("滚动查看更多")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.down")
                .font(.system(size: 10))
                .opacity(0.5)
        }
        .padding(.bottom, 8)
    }

    private var backgroundView: some View {
        VisualEffectView(
            material: .hudWindow,
            blendingMode: .behindWindow
        )
    }
}

// MARK: - Array Extension
extension Array {
    /// 将数组分割成指定大小的子数组
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - DockPreviewItemView
/// 程序坞预览项 - 与切换器窗口项样式一致
struct DockPreviewItemView: View {
    let item: DockPreviewItem
    let isHovered: Bool
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let cachedImage: NSImage?  // 预加载的缓存图片
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    @State private var previewImage: NSImage?

    // 与切换器一致的图标尺寸
    private var iconSize: CGFloat { DesignTokens.WindowItem.iconSize }
    private var iconCornerRadius: CGFloat { DesignTokens.WindowItem.iconCornerRadius }

    // 是否显示应用图标
    private var showAppIcon: Bool { ConfigManager.shared.config.dockPreview.showAppIcon }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // 预览图 - 与切换器一致
            previewContent
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius))

            // 应用信息 - 与切换器一致
            HStack(spacing: DesignTokens.Spacing.xs) {
                if showAppIcon {
                    Image(nsImage: item.appIcon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.appName)
                        .font(.system(size: DesignTokens.WindowItem.titleFontSize, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.label)
                        .lineLimit(1)

                    if !item.windowTitle.isEmpty && item.windowTitle != item.appName {
                        Text(item.windowTitle)
                            .font(.system(size: DesignTokens.WindowItem.subtitleFontSize))
                            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(width: itemWidth, height: itemHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.windowItem)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.windowItem)
                .strokeBorder(
                    isHovered ? DesignTokens.Colors.accent : Color.clear,
                    lineWidth: 2
                )
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onTapGesture(perform: onTap)
        .onHover(perform: onHover)
        .onAppear {
            // 始终重新加载预览，确保获取最新内容
            loadPreview()
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius)
                .fill(DesignTokens.Colors.secondaryBackground)

            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius))
            } else {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .opacity(0.4)
            }
        }
        // 使用实际窗口比例
        .aspectRatio(windowAspectRatio, contentMode: .fit)
    }

    // 计算实际窗口的宽高比
    private var windowAspectRatio: CGFloat {
        let width = item.windowModel.frame.width
        let height = item.windowModel.frame.height
        guard width > 0 && height > 0 else { return 16.0 / 9.0 }
        return width / height
    }

    private var backgroundColor: Color {
        if isHovered {
            return DesignTokens.Colors.selectedBackground
        }
        return Color.clear
    }

    private func loadPreview() {
        Task(priority: .userInitiated) {
            let generator = item.previewGenerator ?? DockPreviewManager.shared.previewGenerator
            if let image = await generator.generatePreview(
                for: item.windowModel,
                size: CGSize(width: previewWidth, height: previewHeight)
            ) {
                await MainActor.run {
                    self.previewImage = image
                }
            }
        }
    }
}

// MARK: - DockPreviewItem
struct DockPreviewItem: Identifiable {
    let id: CGWindowID
    let windowModel: WindowModel
    let windowTitle: String
    let appName: String
    let appIcon: NSImage

    // 共享的 PreviewGenerator 引用
    var previewGenerator: PreviewGenerator?

    init(windowModel: WindowModel) {
        self.id = windowModel.id
        self.windowModel = windowModel
        self.windowTitle = windowModel.windowTitle.isEmpty ? windowModel.appName : windowModel.windowTitle
        self.appName = windowModel.appName
        self.appIcon = windowModel.appIcon
        self.previewGenerator = nil
    }
}

// MARK: - DockPosition
enum DockPosition {
    case top
    case bottom
    case left
    case right

    static func current() -> DockPosition {
        // 从系统获取 Dock 位置
        // 默认返回底部
        return .bottom
    }
}

// MARK: - DockGeometry
struct DockGeometry {
    /// 获取 Dock 的实际位置和尺寸
    static func getDockFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 800, height: 80)
        }

        let screenFrame = screen.frame
        let dockPosition = getDockPosition()
        let dockSize = getDockSize()

        switch dockPosition {
        case .bottom:
            return CGRect(
                x: 0,
                y: 0,
                width: screenFrame.width,
                height: dockSize
            )
        case .top:
            return CGRect(
                x: 0,
                y: screenFrame.height - dockSize,
                width: screenFrame.width,
                height: dockSize
            )
        case .left:
            return CGRect(
                x: 0,
                y: 0,
                width: dockSize,
                height: screenFrame.height
            )
        case .right:
            return CGRect(
                x: screenFrame.width - dockSize,
                y: 0,
                width: dockSize,
                height: screenFrame.height
            )
        }
    }

    /// 获取 Dock 位置
    static func getDockPosition() -> DockPosition {
        if let dockPlist = UserDefaults(suiteName: "com.apple.dock")?.dictionaryRepresentation() {
            let position = dockPlist["orientation"] as? String ?? "bottom"
            switch position {
            case "top": return .top
            case "left": return .left
            case "right": return .right
            default: return .bottom
            }
        }
        return .bottom
    }

    /// 获取 Dock 尺寸（高度或宽度）
    /// 返回 Dock 占据的屏幕区域大小，包含图标、边距和阴影
    static func getDockSize() -> CGFloat {
        let defaults = UserDefaults(suiteName: "com.apple.dock")

        // 获取图标大小设置（默认 48）
        let iconSize = defaults?.double(forKey: "size") ?? 48

        // 边距和阴影 - 适度增加以确保安全
        let topPadding: CGFloat = 8
        let bottomPadding: CGFloat = 8
        let shadowHeight: CGFloat = 5

        // 放大效果预留空间
        let magnification = defaults?.bool(forKey: "magnification") ?? false
        let magnificationBonus: CGFloat = magnification ? 8 : 0

        // 最近使用应用预留
        let showRecents = defaults?.bool(forKey: "show-recents") ?? false
        let recentsBonus: CGFloat = showRecents ? 4 : 0

        // 计算总高度
        let totalHeight = CGFloat(iconSize) + topPadding + bottomPadding + shadowHeight + magnificationBonus + recentsBonus

        // 确保合理的范围
        return max(70, min(140, totalHeight))
    }

    /// 获取推荐间距（基于屏幕分辨率和 Dock 大小）
    /// 返回预览窗口与 Dock 之间的安全间距，确保不遮挡程序坞
    static func getRecommendedSpacing() -> (vertical: CGFloat, horizontal: CGFloat) {
        guard let screen = NSScreen.main else {
            return (vertical: 36, horizontal: 28)
        }

        let screenHeight = screen.frame.height

        // 基础间距：根据屏幕尺寸调整，确保不遮挡 Dock
        let baseSpacing: CGFloat
        if screenHeight < 900 {
            // 小屏幕（MacBook Air 13" 等）
            baseSpacing = 28
        } else if screenHeight < 1100 {
            // 中等屏幕（MacBook Pro 14", iMac 21.5" 等）
            baseSpacing = 32
        } else {
            // 大屏幕（iMac 27", Pro Display XDR 等）
            baseSpacing = 36
        }

        // 垂直间距：额外确保不遮挡 Dock
        let verticalSpacing = baseSpacing + 8

        // 水平间距：用于侧边 Dock
        let horizontalSpacing = baseSpacing

        return (vertical: verticalSpacing, horizontal: horizontalSpacing)
    }
}

// MARK: - 大预览窗口视图 - 复用窗口切换器的背景预览逻辑
struct LargeDockPreviewView: View {
    let item: DockPreviewItem
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let previewGenerator: PreviewGenerator?

    @State private var previewImage: NSImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            // 背景
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignTokens.Colors.secondaryBackground)

            if let image = previewImage {
                // 居中显示，去掉空白区域
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        .frame(width: previewWidth, height: previewHeight)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onAppear {
            loadFullResolutionPreview()
        }
    }

    /// 使用全分辨率预览，类似于窗口切换器的背景预览
    private func loadFullResolutionPreview() {
        Task(priority: .userInitiated) {
            // 使用全分辨率预览生成器
            if let image = await previewGenerator?.generateFullResolutionPreview(for: item.windowModel) {
                await MainActor.run {
                    self.previewImage = image
                    self.isLoading = false
                }
            } else {
                // 降级使用实时预览
                await loadRealTimePreview()
            }
        }
    }

    private func loadRealTimePreview() async {
        let targetSize = CGSize(width: previewWidth * 2, height: previewHeight * 2)
        if let image = await previewGenerator?.generateRealtimePreview(
            for: item.windowModel,
            size: targetSize
        ) {
            await MainActor.run {
                self.previewImage = image
                self.isLoading = false
            }
        } else {
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
}

// MARK: - 实时预览窗口模型
struct RealtimePreviewModel: Identifiable {
    let id: CGWindowID
    let windowModel: WindowModel
    let previewGenerator: PreviewGenerator?

    init(windowModel: WindowModel, previewGenerator: PreviewGenerator?) {
        self.id = windowModel.id
        self.windowModel = windowModel
        self.previewGenerator = previewGenerator
    }
}

// MARK: - 实时预览视图（可被 Command+Tab 和 Dock 预览共用）
struct RealtimePreviewContainer: View {
    let windowModel: WindowModel
    let previewGenerator: PreviewGenerator?
    let targetSize: CGSize

    @State private var previewImage: NSImage?

    var body: some View {
        ZStack {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: windowModel.appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.3)
            }
        }
        .onAppear {
            loadPreview()
        }
    }

    private func loadPreview() {
        Task(priority: .userInitiated) {
            if let image = await previewGenerator?.generateRealtimePreview(
                for: windowModel,
                size: targetSize
            ) {
                await MainActor.run {
                    self.previewImage = image
                }
            }
        }
    }
}

// MARK: - Preview
#if DEBUG
struct DockPreviewPanelView_Previews: PreviewProvider {
    static var previews: some View {
        // 简化预览，不依赖实际 Manager
        Text("DockPreviewPanel Preview")
            .frame(width: 400, height: 200)
            .background(Color.gray)
    }
}
#endif
