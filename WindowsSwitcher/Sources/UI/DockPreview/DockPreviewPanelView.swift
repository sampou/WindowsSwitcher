import SwiftUI
import AppKit
import Combine

// MARK: - DockPreviewManager (Shared Instance)
/// 程序坞预览管理器 - 单例，复用 PreviewGenerator
class DockPreviewManager: ObservableObject {
    static let shared = DockPreviewManager()

    @Published var isPreviewVisible: Bool = false
    @Published var previewItems: [DockPreviewItem] = []
    @Published var currentDockPosition: DockPosition = .bottom
    @Published var hoveredIndex: Int?

    // 共享的 PreviewGenerator 实例
    let previewGenerator = PreviewGenerator()

    private let eventMonitor = DockEventMonitor()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupBindings()
    }

    func start() {
        eventMonitor.startMonitoring()
        Logger.info("DockPreviewManager started")
    }

    func stop() {
        eventMonitor.stopMonitoring()
        isPreviewVisible = false
        Logger.info("DockPreviewManager stopped")
    }

    private func setupBindings() {
        // 监听 Dock 图标悬停
        eventMonitor.$hoveredAppBundleID
            .sink { [weak self] bundleID in
                self?.handleHoverChange(bundleID: bundleID)
            }
            .store(in: &cancellables)

        // 监听 Dock 位置变化
        eventMonitor.$dockPosition
            .assign(to: &$currentDockPosition)
    }

    private func handleHoverChange(bundleID: String?) {
        guard let bundleID = bundleID else {
            hidePreview()
            return
        }

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
        let sortedWindows = windows.sorted { $0.lastActiveTime > $1.lastActiveTime }

        // 创建预览项（注入共享的 PreviewGenerator）
        previewItems = sortedWindows.prefix(4).map { windowModel in
            var item = DockPreviewItem(windowModel: windowModel)
            item.previewGenerator = previewGenerator
            return item
        }

        showPreview()
    }

    private func showPreview() {
        guard !previewItems.isEmpty else {
            return
        }

        withAnimation(DesignTokens.Animation.panelShow) {
            isPreviewVisible = true
        }
    }

    private func hidePreview() {
        withAnimation(DesignTokens.Animation.panelHide) {
            isPreviewVisible = false
            hoveredIndex = nil
        }
    }

    // 公开方法，供外部调用隐藏预览
    public func hidePreviewPanel() {
        hidePreview()
    }

    func selectItem(_ item: DockPreviewItem) {
        // 激活窗口
        WindowManager.shared.activateWindow(item.windowModel)

        // 延迟隐藏预览（给窗口激活留出时间）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.hidePreview()
        }

        // 通知外部（如 AppDelegate）用户已选择窗口
        NotificationCenter.default.post(
            name: .dockPreviewWindowSelected,
            object: nil,
            userInfo: ["windowModel": item.windowModel]
        )

        Logger.info("Activated window: \(item.windowTitle)")
    }
}

// MARK: - DockPreviewPanelView
/// 程序坞预览面板主视图 - 与切换器面板样式一致
struct DockPreviewPanelView: View {
    @ObservedObject var manager: DockPreviewManager
    @ObservedObject private var configManager = ConfigManager.shared
    let onDismiss: () -> Void

    private let maxItems = 4

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

    // 间距与切换器一致
    private var itemSpacing: CGFloat {
        20  // 与 WindowItem.spacing 一致
    }

    var body: some View {
        HStack(spacing: itemSpacing) {
            ForEach(Array(manager.previewItems.prefix(maxItems).enumerated()), id: \.element.id) { index, item in
                DockPreviewItemView(
                    item: item,
                    isHovered: manager.hoveredIndex == index,
                    previewWidth: previewWidth,
                    previewHeight: previewHeight,
                    itemWidth: itemWidth,
                    itemHeight: itemHeight,
                    onTap: {
                        manager.selectItem(item)
                    },
                    onHover: { isHovered in
                        manager.hoveredIndex = isHovered ? index : nil
                    }
                )
            }
        }
        .padding(DesignTokens.Panel.padding)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Panel.cornerRadius))
        .shadow(
            color: .black.opacity(0.25),
            radius: DesignTokens.Panel.shadowRadius,
            x: 0,
            y: DesignTokens.Panel.shadowY
        )
        .position(position)
        .onAppear {
            Logger.info("DockPreviewPanelView appeared")
        }
    }

    private var backgroundView: some View {
        VisualEffectView(
            material: .hudWindow,
            blendingMode: .behindWindow
        )
    }

    private var position: CGPoint {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let dockFrame = DockGeometry.getDockFrame()

        // 根据 Dock 位置和预览项数量动态计算位置
        let itemCount = min(manager.previewItems.count, maxItems)
        let totalWidth = CGFloat(itemCount) * itemWidth + CGFloat(itemCount - 1) * itemSpacing

        switch manager.currentDockPosition {
        case .bottom:
            return CGPoint(
                x: screenFrame.midX,
                y: dockFrame.minY - itemHeight / 2 - 40
            )
        case .top:
            return CGPoint(
                x: screenFrame.midX,
                y: dockFrame.maxY + itemHeight / 2 + 40
            )
        case .left:
            return CGPoint(
                x: dockFrame.maxX + totalWidth / 2 + 20,
                y: screenFrame.midY
            )
        case .right:
            return CGPoint(
                x: dockFrame.minX - totalWidth / 2 - 20,
                y: screenFrame.midY
            )
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
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    @State private var previewImage: NSImage?
    @State private var isInternalHovered = false

    // 与切换器一致的图标尺寸
    private var iconSize: CGFloat { DesignTokens.WindowItem.iconSize }
    private var iconCornerRadius: CGFloat { DesignTokens.WindowItem.iconCornerRadius }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // 预览图 - 与切换器一致
            previewContent
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.WindowItem.previewCornerRadius))

            // 应用信息 - 与切换器一致
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius))

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
        .animation(DesignTokens.Animation.itemHover, value: isHovered)
        .onTapGesture(perform: onTap)
        .onHover(perform: onHover)
        .onAppear {
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
        Task {
            // 使用共享的 PreviewGenerator 实例
            let generator = item.previewGenerator ?? DockPreviewManager.shared.previewGenerator
            previewImage = await generator.generatePreview(
                for: item.windowModel,
                size: CGSize(width: previewWidth, height: previewHeight)
            )
        }
    }
}

// MARK: - DockPreviewItem
struct DockPreviewItem: Identifiable {
    let id: UUID
    let windowModel: WindowModel
    let windowTitle: String
    let appName: String
    let appIcon: NSImage

    // 共享的 PreviewGenerator 引用
    var previewGenerator: PreviewGenerator?

    init(windowModel: WindowModel) {
        self.id = UUID()
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
    static func getDockFrame() -> CGRect {
        // 获取 Dock 的实际位置和尺寸
        // macOS 11+ 可以通过 NSDockTile 获取
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 800, height: 80)
        }

        let screenFrame = screen.frame
        let dockSize: CGFloat = 80 // 默认 Dock 高度

        // 简化实现：假设 Dock 在底部
        return CGRect(
            x: 0,
            y: 0,
            width: screenFrame.width,
            height: dockSize
        )
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
