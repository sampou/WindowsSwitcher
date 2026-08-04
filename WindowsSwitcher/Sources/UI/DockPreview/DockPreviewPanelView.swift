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
        // 即使预览不可见也需要更新鼠标状态，避免 isMouseInPreviewWindow 卡在 true
        let expandedFrame = previewWindowFrame.insetBy(dx: -10, dy: -10)
        let isInPreview = isPreviewVisible && expandedFrame.contains(location)

        eventMonitor.isMouseInPreviewWindow = isInPreview

        guard isPreviewVisible else { return }

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
        // 按窗口 ID 升序排列，最新创建的窗口排在最后面
        // CGWindowID 是系统按创建顺序分配的，ID 越小表示创建越早
        let sortedWindows = windows.sorted { $0.id < $1.id }

        // 创建预览项 - 显示所有窗口，不再限制数量
        previewItems = sortedWindows.map { windowModel in
            var item = DockPreviewItem(windowModel: windowModel)
            item.previewGenerator = previewGenerator
            return item
        }

        // 先加载第一个预览图，减少空白闪烁
        preloadFirstPreviewAndShow(for: sortedWindows)
    }

    // 先加载第一个预览图，再显示面板
    private func preloadFirstPreviewAndShow(for windows: [WindowModel]) {
        let previewSize = ConfigManager.shared.config.appearance.previewSize.dimensions
        let size = CGSize(width: previewSize.width, height: previewSize.height)

        Task(priority: .userInitiated) {
            // 先加载第一个窗口的预览图
            if let firstWindow = windows.first {
                if let image = await self.previewGenerator.generateRealtimePreview(for: firstWindow, size: size) {
                    await MainActor.run {
                        self.previewImages[firstWindow.id] = image
                    }
                }
            }

            // 显示面板
            await MainActor.run {
                showPreview()
            }

            // 继续加载其余预览图
            if windows.count > 1 {
                await withTaskGroup(of: Void.self) { group in
                    for window in windows.dropFirst() {
                        group.addTask {
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
        // 保留预览图缓存，下次显示时可复用，减少闪烁
    }

    // 公开方法，供外部调用隐藏预览
    public func hidePreviewPanel() {
        hidePreview()
    }

    func selectItem(_ item: DockPreviewItem) {
        // 激活前先刷新窗口缓存
        WindowManager.shared.refreshCache()
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
    private var itemSpacing: CGFloat { 8 }   // 行间距
    private var itemPadding: CGFloat { 8 }   // 窗口项外部 padding
    private var panelPadding: CGFloat { DesignTokens.Panel.padding }

    // MARK: - 滚动相关配置

    /// 最大面板高度占屏幕高度的比例
    private let maxPanelHeightRatio: CGFloat = 0.6

    /// 最大显示行数（用于计算最大高度阈值）
    private let absoluteMaxRows: Int = 5

    /// 计算总行数
    private var totalRows: Int {
        let count = manager.previewItems.count
        return (count + itemsPerRow - 1) / itemsPerRow
    }

    /// 获取屏幕可用高度（考虑 Dock 和菜单栏）
    private var availableScreenHeight: CGFloat {
        guard let screen = NSScreen.main else {
            return 800  // 默认值
        }
        // visibleFrame 已经排除了 Dock 和菜单栏
        return screen.visibleFrame.height
    }

    /// 计算每行的实际高度（包含 itemPadding）
    private var actualRowHeight: CGFloat {
        itemHeight + itemPadding * 2
    }

    /// 内容区域高度（所有行的总高度，包含行间距）
    private var contentRowsHeight: CGFloat {
        guard totalRows > 0 else { return 0 }
        return CGFloat(totalRows) * actualRowHeight + CGFloat(totalRows - 1) * itemSpacing
    }

    /// 实际内容高度（包含 panelPadding）
    private var actualContentHeight: CGFloat {
        // 内容高度 + 上下 padding
        return contentRowsHeight + panelPadding * 2
    }

    /// 最大内容高度限制（包含 panelPadding）
    private var maxPanelContentHeight: CGFloat {
        // 基于行数计算最大高度（包含 padding）
        let maxByRows = CGFloat(absoluteMaxRows) * actualRowHeight + CGFloat(absoluteMaxRows - 1) * itemSpacing + panelPadding * 2
        // 基于屏幕比例计算最大高度
        let maxByRatio = availableScreenHeight * maxPanelHeightRatio
        return min(maxByRatio, maxByRows)
    }

    /// 是否需要滚动（内容超出最大高度阈值）
    private var needsScrolling: Bool {
        actualContentHeight > maxPanelContentHeight
    }

    /// 显示区域高度（用于 ScrollView）
    private var displayHeight: CGFloat {
        // 实际内容高度或最大高度，取较小值
        let height = needsScrolling ? maxPanelContentHeight : actualContentHeight
        // 确保不超过可用的内容高度
        return min(height, actualContentHeight)
    }

    /// 滚动指示器透明度（平滑过渡）
    @State private var scrollIndicatorOpacity: Double = 0

    /// 当前滚动位置
    @State private var scrollPosition: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // 滚动区域
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    // 主滚动视图
                    ControllableScrollView(scrollPosition: $scrollPosition) { position in
                        // 滚动回调（可选，用于额外处理）
                    } content: {
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
                    .frame(maxHeight: displayHeight)

                    // 自定义滚动条（支持拖动交互）
                    if needsScrolling {
                        ScrollBar(
                            totalHeight: actualContentHeight,
                            visibleHeight: geometry.size.height,
                            scrollPosition: scrollPosition,
                            opacity: scrollIndicatorOpacity,
                            onScroll: { targetPosition in
                                // 滚动条拖动时更新滚动位置
                                scrollPosition = targetPosition
                            }
                        )
                        .padding(.trailing, 4)
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                    }
                }
                .onAppear {
                    updateScrollIndicatorOpacity()
                }
                .onChange(of: needsScrolling) { _ in
                    updateScrollIndicatorOpacity()
                }
            }
            .frame(height: displayHeight)

            // 滚动提示（仅当内容超出显示区域时显示）
            if needsScrolling {
                scrollIndicatorView
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

    /// 更新滚动条透明度（平滑动画）
    private func updateScrollIndicatorOpacity() {
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollIndicatorOpacity = needsScrolling ? 1 : 0
        }
    }

    // 滚动提示视图
    private var scrollIndicatorView: some View {
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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.05))
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

    // 总面板高度
    private var totalPanelHeight: CGFloat {
        var height = displayHeight + panelPadding * 2
        if needsScrolling {
            height += 28  // 滚动提示高度
        }
        return height
    }

    private var backgroundView: some View {
        VisualEffectView(
            material: .hudWindow,
            blendingMode: .behindWindow
        )
    }
}

// MARK: - 自定义滚动条组件（支持拖动交互）
struct ScrollBar: View {
    let totalHeight: CGFloat
    let visibleHeight: CGFloat
    let scrollPosition: CGFloat
    let opacity: Double

    // 滚动回调
    var onScroll: ((CGFloat) -> Void)? = nil

    // 拖动状态
    @State private var isDragging: Bool = false
    @State private var dragStartY: CGFloat = 0
    @State private var dragStartScrollPosition: CGFloat = 0

    // 计算滚动条高度（最小 30pt，最大不超过可见区域的 80%）
    private var thumbHeight: CGFloat {
        guard totalHeight > 0 else { return 0 }
        let ratio = visibleHeight / totalHeight
        return max(30, min(visibleHeight * ratio, visibleHeight * 0.8))
    }

    // 计算滚动条位置
    private var thumbOffset: CGFloat {
        guard totalHeight > visibleHeight else { return 0 }
        let maxScrollOffset = totalHeight - visibleHeight
        let maxThumbOffset = visibleHeight - thumbHeight
        let scrollRatio = maxScrollOffset > 0 ? scrollPosition / maxScrollOffset : 0
        return min(maxThumbOffset, max(0, scrollRatio * maxThumbOffset))
    }

    var body: some View {
        GeometryReader { geometry in
            // 滚动条轨道（点击可快速跳转）
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear)
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTrackTap(location: location, in: geometry.size.height)
                }
                .overlay(
                    // 滚动条滑块
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isDragging ? Color.secondary.opacity(0.8) : Color.secondary.opacity(0.5 * opacity))
                        .frame(width: isDragging ? 6 : 4, height: thumbHeight)
                        .offset(y: thumbOffset)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    handleDragChanged(value: value, in: geometry.size.height)
                                }
                                .onEnded { _ in
                                    handleDragEnded()
                                }
                        )
                        .animation(.easeInOut(duration: 0.15), value: isDragging)
                        .padding(.trailing, 4)
                )
        }
        .frame(width: 16)
    }

    // 处理轨道点击（快速跳转）
    private func handleTrackTap(location: CGPoint, in trackHeight: CGFloat) {
        guard totalHeight > visibleHeight else { return }

        // 计算点击位置对应的目标滚动位置
        let clickRatio = location.y / trackHeight
        let maxScrollOffset = totalHeight - visibleHeight
        let targetScrollPosition = clickRatio * maxScrollOffset

        onScroll?(targetScrollPosition)
    }

    // 处理拖动开始
    private func handleDragChanged(value: DragGesture.Value, in trackHeight: CGFloat) {
        if !isDragging {
            isDragging = true
            dragStartY = value.startLocation.y
            dragStartScrollPosition = scrollPosition
        }

        guard totalHeight > visibleHeight else { return }

        // 计算拖动距离对应滚动距离
        let dragDelta = value.location.y - dragStartY
        let maxThumbOffset = trackHeight - thumbHeight
        let maxScrollOffset = totalHeight - visibleHeight

        // 将拖动距离转换为滚动距离
        let scrollDelta = maxThumbOffset > 0 ? (dragDelta / maxThumbOffset) * maxScrollOffset : 0
        let targetScrollPosition = max(0, min(maxScrollOffset, dragStartScrollPosition + scrollDelta))

        onScroll?(targetScrollPosition)
    }

    // 处理拖动结束
    private func handleDragEnded() {
        withAnimation(.easeOut(duration: 0.15)) {
            isDragging = false
        }
    }
}

// MARK: - 滚动视图包装器（支持滚动位置控制和追踪）
struct ControllableScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    @Binding var scrollPosition: CGFloat
    var onScroll: ((CGFloat) -> Void)?

    init(scrollPosition: Binding<CGFloat>, onScroll: ((CGFloat) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self._scrollPosition = scrollPosition
        self.onScroll = onScroll
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // 设置内容视图
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView

        // 监听滚动事件
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // 更新内容
        if let hostingView = scrollView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
        }

        // 检查是否需要程序化滚动（外部修改了 scrollPosition）
        let currentScrollY = scrollView.contentView.bounds.origin.y
        let targetScrollY = scrollPosition

        // 如果目标位置与当前位置不同，且差距超过阈值（避免浮点误差导致的循环）
        if abs(currentScrollY - targetScrollY) > 1.0 {
            // 标记为程序化滚动，防止触发 boundsDidChange 中的循环更新
            context.coordinator.isProgrammaticScroll = true
            let newOrigin = NSPoint(x: 0, y: max(0, targetScrollY))
            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // 延迟重置标志
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                context.coordinator.isProgrammaticScroll = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: ControllableScrollView
        var scrollView: NSScrollView?
        var isProgrammaticScroll: Bool = false

        init(_ parent: ControllableScrollView) {
            self.parent = parent
        }

        @objc func boundsDidChange(_ notification: Notification) {
            // 如果是程序化滚动触发的，跳过更新以避免循环
            guard !isProgrammaticScroll else { return }

            guard let clipView = notification.object as? NSClipView else { return }
            let newScrollPosition = clipView.bounds.origin.y

            // 更新绑定的滚动位置
            DispatchQueue.main.async { [weak self] in
                self?.parent.scrollPosition = newScrollPosition
                self?.parent.onScroll?(newScrollPosition)
            }
        }
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
            // 优先使用缓存图片，没有缓存时才加载
            if cachedImage != nil {
                previewImage = cachedImage
            } else {
                loadPreview()
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        ZStack {
            // 透明背景：窗口预览图按真实比例显示时不露出灰色填充边框
            RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius)
                .fill(Color.clear)

            // 优先显示预览图，其次显示缓存图片，最后显示占位图标
            if let image = previewImage ?? cachedImage {
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
            // 使用实时预览方法，确保获取最新窗口内容
            if let image = await generator.generateRealtimePreview(
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
        // 完全参考切换器背景预览 BackgroundPreviewContainer 的布局方式
        ZStack {
            if let image = previewImage {
                // 获取屏幕和窗口信息
                let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
                let windowFrame = item.windowModel.frame

                // 窗口的尺寸和位置
                let imgWidth = image.size.width
                let imgHeight = image.size.height
                let imgX = windowFrame.origin.x
                let imgY = windowFrame.origin.y

                ZStack {
                    Color.clear

                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imgWidth, height: imgHeight)
                        .position(x: imgX + imgWidth / 2, y: imgY + imgHeight / 2)
                }
            } else if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onAppear {
            loadFullResolutionPreview()
        }
    }

    /// 使用全分辨率预览，类似于窗口切换器的背景预览
    private func loadFullResolutionPreview() {
        // 如果已有图片且是相同窗口，直接使用
        if previewImage != nil && !isLoading {
            return
        }

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
