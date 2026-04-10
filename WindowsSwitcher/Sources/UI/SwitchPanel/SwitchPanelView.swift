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

    // 每行显示的窗口数 - 自适应
    private var columnCount: Int {
        // 如果用户设置了固定列数，使用设置值
        if configManager.config.appearance.switcherColumns > 0 {
            return configManager.config.appearance.switcherColumns
        }

        // 自动计算
        let itemWidth = previewSize.itemDimensions.width
        let desiredSpacing: CGFloat = 16
        let maxPanelWidth: CGFloat = 1400

        return max(3, min(8, Int((maxPanelWidth - DesignTokens.Panel.padding * 2) / (itemWidth + desiredSpacing))))
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

    // 面板自适应宽度
    private var panelWidth: CGFloat {
        let itemWidth = previewSize.itemDimensions.width
        let desiredSpacing: CGFloat = 16
        let minWidth: CGFloat = 500
        // 最大宽度为屏幕宽度的 90%
        let maxWidth = screenSize.width * 0.9
        let contentWidth = CGFloat(columnCount) * (itemWidth + desiredSpacing) - desiredSpacing + DesignTokens.Panel.padding * 2
        return min(max(contentWidth, minWidth), maxWidth)
    }

    // 面板自适应高度
    private var panelHeight: CGFloat {
        let itemHeight = previewSize.itemDimensions.height
        let windowCount = viewModel.filteredWindows.count
        let rowCount = max(1, (windowCount + columnCount - 1) / columnCount)
        let minHeight: CGFloat = 400
        // 最大高度为屏幕高度的 80%
        let maxHeight = screenSize.height * 0.8
        let contentHeight = CGFloat(rowCount) * (itemHeight + 16) + DesignTokens.Panel.padding * 2 + 40 // 40是底部快捷栏
        return min(max(contentHeight, minHeight), maxHeight)
    }

    // 用于自动滚动到选中项
    @State private var selectedScrollID: CGWindowID?

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
            onNext: { viewModel.selectNext() },
            onPrev: { viewModel.selectPrevious() },
            onConfirm: { viewModel.activateSelected(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { onDismiss() } },
            onDismiss: onDismiss,
            onSelectIndex: { idx in
                if viewModel.filteredWindows.indices.contains(idx) {
                    viewModel.selectedIndex = idx
                }
            },
            onMoveUp: { viewModel.selectUp() },
            onMoveDown: { viewModel.selectDown() }
        ))
        .onChange(of: viewModel.selectedIndex) { (newIndex: Int) in
            // 简化：只在有效索引时设置
            guard newIndex >= 0 && newIndex < viewModel.filteredWindows.count else { return }
            selectedScrollID = viewModel.filteredWindows[newIndex].id
        }
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
                                    isSelected: index == viewModel.selectedIndex,
                                    previewImage: viewModel.previewImages[window.id],
                                    onSelect: { viewModel.selectedIndex = index },
                                    onActivate: {
                                        viewModel.selectedIndex = index
                                        viewModel.activateSelected()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { onDismiss() }
                                    },
                                    onClose: { viewModel.closeWindow(window) },
                                    onMinimize: { viewModel.minimizeWindow(window) }
                                )
                                .id(window.id)
                            }
                        }
                        // 移除 drawingGroup，因为它会导致每次更新都重新光栅化整个视图
                        // .drawingGroup()
                        .onChange(of: selectedScrollID) { newID in
                            // 只在非空时滚动，避免空值触发
                            if let windowID = newID {
                                withAnimation(.none) {
                                    proxy.scrollTo(windowID, anchor: .center)
                                }
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
        // Escape 没有 specialKey，用 keyCode 53
        if event.keyCode == 53 {
            Logger.info("==> ESC pressed, hiding panel")
            onDismiss?(); return
        }
        switch event.specialKey {
        case .tab:
            if event.modifierFlags.contains(.shift) { onPrev?() }
            else { onNext?() }
        case .carriageReturn, .enter, .newline:
            onConfirm?()
        case .leftArrow:
            onPrev?()  // 左：上一项
        case .rightArrow:
            onNext?()  // 右：下一项
        case .upArrow:
            onMoveUp?()  // 上：上一行同列
        case .downArrow:
            onMoveDown?()  // 下：下一行同列
        default:
            if let n = Int(chars), (1...9).contains(n) {
                onSelectIndex?(n - 1)
            } else {
                super.keyDown(with: event)
            }
        }
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
