import SwiftUI
import AppKit

struct SwitchPanelView: View {
    @ObservedObject var viewModel: SwitchPanelViewModel
    let onDismiss: () -> Void

    // 每行显示的窗口数 - 根据面板宽度动态计算，确保每个窗口有足够空间
    private var columns: [GridItem] {
        let panelWidth = DesignTokens.Panel.width
        let itemWidth = DesignTokens.WindowItem.width
        let desiredSpacing: CGFloat = 30  // 期望的间距
        // 计算可以容纳的列数：(面板宽度 + 间距) / (窗口宽度 + 间距)
        let columnCount = max(3, min(6, Int((panelWidth + desiredSpacing) / (itemWidth + desiredSpacing))))
        return (0..<columnCount).map { _ in
            GridItem(.fixed(itemWidth), spacing: desiredSpacing)
        }
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
        .frame(width: DesignTokens.Panel.width, height: DesignTokens.Panel.height)
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
            }
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

    func makeNSView(context: Context) -> KeyCatchView {
        let view = KeyCatchView()
        view.onNext = onNext
        view.onPrev = onPrev
        view.onConfirm = onConfirm
        view.onDismiss = onDismiss
        view.onSelectIndex = onSelectIndex
        return view
    }

    func updateNSView(_ nsView: KeyCatchView, context: Context) {
        nsView.onNext = onNext
        nsView.onPrev = onPrev
        nsView.onConfirm = onConfirm
        nsView.onDismiss = onDismiss
        nsView.onSelectIndex = onSelectIndex
    }
}

class KeyCatchView: NSView {
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSelectIndex: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        // Escape 没有 specialKey，用 keyCode 53
        if event.keyCode == 53 { onDismiss?(); return }
        switch event.specialKey {
        case .tab:
            if event.modifierFlags.contains(.shift) { onPrev?() }
            else { onNext?() }
        case .carriageReturn, .enter, .newline:
            onConfirm?()
        case .leftArrow, .downArrow:
            onPrev?()
        case .rightArrow, .upArrow:
            onNext?()
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
