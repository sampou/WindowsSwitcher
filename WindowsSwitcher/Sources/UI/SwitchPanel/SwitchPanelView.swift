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
                // 获取屏幕和窗口信息
                let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
                let windowFrame = selectedWindow.frame

                // 计算窗口在屏幕上的相对位置和大小
                let viewWidth = screenFrame.width
                let viewHeight = screenFrame.height

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

struct SwitchPanelView: View {
    @ObservedObject var viewModel: SwitchPanelViewModel
    @ObservedObject private var configManager = ConfigManager.shared
    let onDismiss: () -> Void

    // 动态获取预览尺寸
    private var previewSize: PreviewSize {
        configManager.config.appearance.previewSize
    }

    // 每行显示的窗口数 - 根据窗口数量自适应
    private var columnCount: Int {
        let windowCount = viewModel.filteredWindows.count

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
        let itemHeight = previewSize.itemDimensions.height
        let actualItemHeight = itemHeight + 8  // 紧凑间距
        let windowCount = viewModel.filteredWindows.count
        let rowCount = max(1, (windowCount + columnCount - 1) / columnCount)

        let bottomBarHeight: CGFloat = 20  // 精简底部栏
        let panelPadding: CGFloat = 8

        // 内容所需高度
        let contentHeight = CGFloat(rowCount) * actualItemHeight + panelPadding * 2 + bottomBarHeight

        // 最小高度
        let minHeight: CGFloat
        switch windowCount {
        case 1, 2, 3, 4:
            minHeight = actualItemHeight + panelPadding * 2 + bottomBarHeight
        default:
            minHeight = 180
        }

        let maxHeight = screenSize.height * 0.8
        return min(max(contentHeight, minHeight), maxHeight)
    }

    var body: some View {
        ZStack {
            // 毛玻璃背景
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Panel.cornerRadius))

            // 窗口网格 - 平铺显示，与屏幕边框保持距离
            windowGrid
                .padding(DesignTokens.Panel.padding)
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
        .accessibilityHint("使用 Tab 键导航，按 Enter 切换窗口，按 Escape 退出")
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
                                    isSelected: window.id == viewModel.selectedWindow?.id,
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
                        // 禁用自动滚动以提升性能
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
    var onSelectIndex: ((Int) -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil    // 上方向键
    var onMoveDown: (() -> Void)? = nil  // 下方向键

    func makeNSView(context: Context) -> KeyCatchView {
        let view = KeyCatchView()
        view.onNext = onNext
        view.onPrev = onPrev
        view.onConfirm = onConfirm
        view.onDismiss = onDismiss
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
    var onSelectIndex: ((Int) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""

        // 只处理以下按键，其他按键不关闭面板，直接忽略
        // ESC (keyCode 53) - 关闭面板
        if event.keyCode == 53 {
            Logger.info("==> ESC pressed, hiding panel")
            onDismiss?()
            return
        }

        // Tab / Shift+Tab - 在应用间导航
        if event.specialKey == .tab {
            if event.modifierFlags.contains(.shift) {
                onPrev?()
            } else {
                onNext?()
            }
            return
        }

        // Enter/Return - 确认选择
        if let specialKey = event.specialKey,
           [.carriageReturn, .enter, .newline].contains(specialKey) {
            onConfirm?()
            return
        }

        // 方向键 - 导航
        switch event.specialKey {
        case .leftArrow:
            onPrev?()  // 左：上一项
        case .rightArrow:
            onNext?()  // 右：下一项
        case .upArrow:
            onMoveUp?()  // 上：上一行同列
        case .downArrow:
            onMoveDown?()  // 下：下一行同列
        default:
            break
        }

        // 数字键 1-9 - 快速选择
        if let n = Int(chars), (1...9).contains(n) {
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
