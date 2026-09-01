import SwiftUI
import AppKit

// MARK: - 背景预览容器视图
/// 按窗口实际大小和位置显示预览
struct BackgroundPreviewContainer: View {
    let selectedWindow: WindowModel
    @State private var previewImage: NSImage?
    @State private var currentWindowID: CGWindowID?

    var body: some View {
        ZStack {
            if let image = previewImage {
                let windowFrame = selectedWindow.frame

                // 窗口的相对尺寸
                let imgWidth = windowFrame.width
                let imgHeight = windowFrame.height
                let imgX = windowFrame.origin.x
                let imgY = windowFrame.origin.y

                // 使用 ZStack 定位
                ZStack {
                    Color.clear

                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imgWidth, height: imgHeight)
                        .position(x: imgX + imgWidth / 2, y: imgY + imgHeight / 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadPreview()
        }
        .onChange(of: selectedWindow.id) { _ in
            loadPreview()
        }
    }

    private func loadPreview() {
        guard currentWindowID != selectedWindow.id else { return }
        currentWindowID = selectedWindow.id

        Task {
            let generator = PreviewGenerator()
            if let image = await generator.generateFullResolutionPreview(for: selectedWindow) {
                await MainActor.run {
                    self.previewImage = image
                }
            }
        }
    }
}

/// 切换面板高度的纯计算器，供 SwiftUI 根视图和宿主 NSPanel 共用。
enum SwitchPanelLayout {
    static let itemVerticalSpacing: CGFloat = 8
    static let bottomBarHeight: CGFloat = 20
    static let panelPadding: CGFloat = 8
    static let defaultMinimumHeight: CGFloat = 180

    static func panelHeight(
        windowCount: Int,
        columnCount: Int,
        itemHeight: CGFloat,
        screenHeight: CGFloat,
        searchAreaHeight: CGFloat
    ) -> CGFloat {
        let safeColumnCount = max(1, columnCount)
        let rowCount = max(1, (windowCount + safeColumnCount - 1) / safeColumnCount)
        let singleRowHeight = itemHeight
            + itemVerticalSpacing
            + panelPadding * 2
            + bottomBarHeight
            + searchAreaHeight
        let contentHeight = CGFloat(rowCount) * (itemHeight + itemVerticalSpacing)
            + panelPadding * 2
            + bottomBarHeight
            + searchAreaHeight
        let baseMinimumHeight = max(
            defaultMinimumHeight,
            panelPadding * 2 + bottomBarHeight + searchAreaHeight
        )
        let minimumHeight = (1...4).contains(windowCount) ? singleRowHeight : baseMinimumHeight
        let maximumHeight = screenHeight * 0.8
        return min(max(contentHeight, minimumHeight), maximumHeight)
    }
}

struct SwitchPanelView: View {
    static let searchAreaHeight: CGFloat = 48

    @ObservedObject var viewModel: SwitchPanelViewModel
    @ObservedObject private var configManager = ConfigManager.shared
    let onDismiss: () -> Void
    let onOpenLayout: (WindowModel) -> Void
    let focusSearchOnAppear: Bool

    init(
        viewModel: SwitchPanelViewModel,
        focusSearchOnAppear: Bool = false,
        onOpenLayout: @escaping (WindowModel) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.focusSearchOnAppear = focusSearchOnAppear
        self.onOpenLayout = onOpenLayout
        self.onDismiss = onDismiss
    }

    /// 搜索栏与 ViewModel 的唯一连接点，便于验证 UI 绑定契约。
    var searchTextBinding: Binding<String> {
        $viewModel.searchText
    }

    // 动态获取预览尺寸
    private var previewSize: PreviewSize {
        configManager.config.appearance.previewSize
    }

    // 每行显示的窗口数 - 根据窗口数量自适应
    private var columnCount: Int {
        let windowCount = viewModel.filteredWindows.count

        // 如果没有窗口，返回 1 避免除以零
        guard windowCount > 0 else { return 1 }

        // 如果用户设置了固定列数，使用设置值
        if configManager.config.appearance.switcherColumns > 0 {
            return min(configManager.config.appearance.switcherColumns, windowCount)
        }

        // 自动计算：根据窗口数量动态调整
        let itemWidth = previewSize.itemDimensions.width
        let desiredSpacing: CGFloat = 16
        let maxPanelWidth: CGFloat = 1400

        // 基础列数计算
        let calculatedColumns = max(1, min(8, Int((maxPanelWidth - DesignTokens.Panel.padding * 2) / (itemWidth + desiredSpacing))))

        // 根据窗口数量调整：不超过窗口数量
        return min(calculatedColumns, windowCount)
    }

    private var columns: [GridItem] {
        let itemWidth = previewSize.itemDimensions.width
        let desiredSpacing: CGFloat = 16
        return (0..<columnCount).map { _ in
            GridItem(.fixed(itemWidth), spacing: desiredSpacing)
        }
    }

    // 获取屏幕尺寸
    private var screenSize: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    // 面板自适应宽度 - 完全贴合内容
    private var panelWidth: CGFloat {
        let itemWidth = previewSize.itemDimensions.width
        let desiredSpacing: CGFloat = 16
        let windowCount = viewModel.filteredWindows.count
        let panelPadding: CGFloat = 8

        // 内容所需宽度
        let contentWidth = CGFloat(columnCount) * (itemWidth + desiredSpacing) - desiredSpacing + panelPadding * 2

        // 最小宽度
        let minWidth: CGFloat
        switch windowCount {
        case 1:
            minWidth = itemWidth + panelPadding * 2 + 8
        case 2:
            minWidth = itemWidth * 2 + desiredSpacing + panelPadding * 2 + 8
        case 3, 4:
            let cols = min(windowCount, columnCount)
            minWidth = itemWidth * CGFloat(cols) + desiredSpacing * CGFloat(cols - 1) + panelPadding * 2 + 8
        default:
            minWidth = 300
        }

        let maxWidth = screenSize.width * 0.9
        return min(max(contentWidth, minWidth), maxWidth)
    }

    // 面板自适应高度 - 完全贴合内容
    private var panelHeight: CGFloat {
        SwitchPanelLayout.panelHeight(
            windowCount: viewModel.filteredWindows.count,
            columnCount: columnCount,
            itemHeight: previewSize.itemDimensions.height,
            screenHeight: screenSize.height,
            searchAreaHeight: Self.searchAreaHeight
        )
    }

    var body: some View {
        ZStack {
            // 毛玻璃背景
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Panel.cornerRadius))

            VStack(spacing: 0) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    SearchBarView(
                        text: searchTextBinding,
                        requestsFocusOnAppear: focusSearchOnAppear
                    )

                    Button(action: openLayoutPanel) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 28)
                            .background(DesignTokens.Colors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.selectedWindow == nil)
                    .accessibilityLabel("打开窗口布局面板")
                    .accessibilityHint("也可按 L 键打开")
                }
                    .padding(.horizontal, DesignTokens.Panel.padding)
                    .padding(.top, DesignTokens.Panel.padding)
                    .padding(.bottom, DesignTokens.Spacing.sm)

                // 窗口网格 - 平铺显示，与屏幕边框保持距离
                windowGrid
                    .padding(.horizontal, DesignTokens.Panel.padding)
                    .padding(.bottom, DesignTokens.Panel.padding)
            }
        }
        // 增大面板尺寸以显示更多窗口
        .frame(width: panelWidth, height: panelHeight)
        .shadow(color: .black.opacity(0.25), radius: DesignTokens.Panel.shadowRadius,
                x: 0, y: DesignTokens.Panel.shadowY)
        .background(KeyEventHandler(
            onNext: {
                viewModel.selectNext()
            },
            onPrev: {
                viewModel.selectPrevious()
            },
            onConfirm: {
                // 使用 selectedWindowID 直接激活（与鼠标点击逻辑一致）
                if let windowID = viewModel.selectedWindowID {
                    viewModel.activateWindowByID(windowID)
                } else {
                    viewModel.activateSelected()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { onDismiss() }
            },
            onDismiss: onDismiss,
            onOpenActions: openLayoutPanel,
            onSelectIndex: { idx in
                if viewModel.filteredWindows.indices.contains(idx) {
                    // 同时设置窗口 ID 和索引，确保同步
                    viewModel.selectedWindowID = viewModel.filteredWindows[idx].id
                    viewModel.selectedIndex = idx
                }
            },
            onMoveUp: { viewModel.selectUp() },
            onMoveDown: { viewModel.selectDown() }
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("窗口切换面板")
        .accessibilityHint("使用 Tab 键导航，按 Enter 切换窗口，按 L 打开布局面板，按 Escape 退出")
    }

    private func openLayoutPanel() {
        guard let selectedWindow = viewModel.selectedWindow else { return }
        onOpenLayout(selectedWindow)
    }

    // MARK: - 窗口网格
    private var windowGrid: some View {
        Group {
            if viewModel.filteredWindows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 0) {
                            ForEach(Array(viewModel.filteredWindows.enumerated()), id: \.element.id) { index, window in
                                WindowItemView(
                                    window: window,
                                    isSelected: window.id == viewModel.selectedWindowID,
                                    previewImage: viewModel.previewImages[window.id],
                                    onSelect: {
                                        // 同时设置索引和窗口 ID，确保同步
                                        viewModel.selectedWindowID = window.id
                                        viewModel.selectedIndex = index
                                    },
                                    onActivate: {
                                        // 直接通过窗口 ID 激活，确保准确性
                                        viewModel.activateWindowByID(window.id)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { onDismiss() }
                                    },
                                    onClose: { viewModel.closeWindow(window) },
                                    onMinimize: { viewModel.minimizeWindow(window) }
                                )
                                .id(window.id)
                            }
                        }
                    }
                    // 当选中窗口变化时，自动滚动到可视范围
                    .onChange(of: viewModel.selectedWindowID) { newID in
                        if let windowID = newID {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(windowID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 空状态
    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 36))
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            Text("没有找到窗口")
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部快捷键提示栏
    private var shortcutBar: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            shortcutHint("⌥ Tab", label: "切换")
            shortcutHint("⌥ ⇧ Tab", label: "反向")
            shortcutHint("⌥ `", label: "应用内")
            shortcutHint("Esc", label: "退出")
        }
        .padding(.horizontal, DesignTokens.Panel.padding)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
    }

    private func shortcutHint(_ key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.label)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DesignTokens.Colors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
        }
    }
}

// MARK: - 键盘事件处理（兼容 macOS 13）
struct KeyEventHandler: NSViewRepresentable {
    let onNext: () -> Void
    let onPrev: () -> Void
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    var onOpenActions: (() -> Void)? = nil
    var onSelectIndex: ((Int) -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil    // 上方向键
    var onMoveDown: (() -> Void)? = nil  // 下方向键

    func makeNSView(context: Context) -> KeyCatchView {
        let view = KeyCatchView()
        view.onNext = onNext
        view.onPrev = onPrev
        view.onConfirm = onConfirm
        view.onDismiss = onDismiss
        view.onOpenActions = onOpenActions
        view.onSelectIndex = onSelectIndex
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        return view
    }

    func updateNSView(_ nsView: KeyCatchView, context: Context) {
        nsView.onNext = onNext
        nsView.onPrev = onPrev
        nsView.onConfirm = onConfirm
        nsView.onDismiss = onDismiss
        nsView.onOpenActions = onOpenActions
        nsView.onSelectIndex = onSelectIndex
        nsView.onMoveUp = onMoveUp
        nsView.onMoveDown = onMoveDown
    }
}

class KeyCatchView: NSView {
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenActions: (() -> Void)?
    var onSelectIndex: ((Int) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""

        // 只处理以下按键，其他按键不关闭面板，直接忽略
        // ESC (keyCode 53) - 关闭面板
        if event.keyCode == 53 {
            Logger.keyEvent("ESC", action: "按下")
            Logger.info("==> ESC pressed, hiding panel")
            onDismiss?()
            return
        }

        // L - 打开当前选中窗口的布局面板
        if chars.lowercased() == "l" {
            Logger.keyEvent("L", action: "打开窗口布局面板")
            onOpenActions?()
            return
        }

        // Tab / Shift+Tab - 在应用间导航
        if event.specialKey == .tab {
            if event.modifierFlags.contains(.shift) {
                Logger.keyEvent("Shift+Tab", action: "反向切换")
                onPrev?()
            } else {
                Logger.keyEvent("Tab", action: "正向切换")
                onNext?()
            }
            return
        }

        // Enter/Return - 确认选择
        if let specialKey = event.specialKey,
           [.carriageReturn, .enter, .newline].contains(specialKey) {
            Logger.keyEvent("Enter", action: "确认选择")
            onConfirm?()
            return
        }

        // 方向键 - 导航
        switch event.specialKey {
        case .leftArrow:
            Logger.keyEvent("←", action: "上一项")
            onPrev?()  // 左：上一项
        case .rightArrow:
            Logger.keyEvent("→", action: "下一项")
            onNext?()  // 右：下一项
        case .upArrow:
            Logger.keyEvent("↑", action: "上一行")
            onMoveUp?()  // 上：上一行同列
        case .downArrow:
            Logger.keyEvent("↓", action: "下一行")
            onMoveDown?()  // 下：下一行同列
        default:
            break
        }

        // 数字键 1-9 - 快速选择
        if let n = Int(chars), (1...9).contains(n) {
            Logger.keyEvent(chars, action: "快速选择第\(n)项")
            onSelectIndex?(n - 1)
            return
        }

        // 其他所有按键：不执行任何操作，不关闭面板，保持切换器显示
        Logger.debug("==> Key ignored (no action): keyCode=\(event.keyCode), chars=\(chars)")
    }
}

// MARK: - NSVisualEffectView 包装
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
