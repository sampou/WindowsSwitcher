import AppKit
import SwiftUI

/// 布局面板的稳定尺寸规则。
enum ActionPanelLayoutMetrics {
    static let width: CGFloat = 460
    static let minimumHeight: CGFloat = 520
    static let preferredHeight: CGFloat = 680
    static let screenVerticalMargin: CGFloat = 64

    /// 根据目标屏幕可用高度计算首次显示高度。
    static func panelHeight(forVisibleScreenHeight height: CGFloat) -> CGFloat {
        min(preferredHeight, max(minimumHeight, height - screenVerticalMargin))
    }
}

/// Action Panel 给用户展示的类型化反馈。
enum ActionPanelFeedback: Equatable {
    case idle
    case success(String)
    case constrained(String)
    case failure(String)

    init(result: WindowLayoutResult) {
        switch result {
        case .applied:
            self = .success("窗口布局已应用")
        case .constrained:
            self = .constrained("应用已调整目标尺寸，请检查实际结果")
        case .skipped(let failure):
            self = .failure(Self.message(for: failure))
        }
    }

    var message: String? {
        switch self {
        case .idle: return nil
        case .success(let message), .constrained(let message), .failure(let message): return message
        }
    }

    private static func message(for failure: WindowLayoutFailure) -> String {
        switch failure {
        case .accessibilityPermissionMissing:
            return "需要辅助功能权限才能调整窗口"
        case .windowNotFound:
            return "窗口已关闭或不再可用"
        case .nonStandardWindow:
            return "该窗口不是可调整的标准窗口"
        case .fullScreenWindow:
            return "全屏窗口不会被自动退出全屏"
        case .positionNotWritable:
            return "该窗口不允许修改位置"
        case .sizeNotWritable:
            return "该窗口不允许修改尺寸"
        case .targetDisplayUnavailable:
            return "没有可用的目标显示器"
        case .writeFailed(let code):
            return "窗口调整失败（错误 \(code)）"
        case .verificationFailed:
            return "无法验证窗口调整结果"
        }
    }
}

/// 独立窗口布局 Action Panel。
struct ActionPanelView: View {
    let window: WindowModel
    let layoutService: any WindowLayoutServicing
    let hotKeyConfig: WindowLayoutHotKeyConfig
    let panelHeight: CGFloat
    let onActivate: () -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex = 0
    @State private var feedback: ActionPanelFeedback = .idle

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Panel.cornerRadius))

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                header

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(WindowLayoutActionCatalog.actions.enumerated()), id: \.element.id) { index, action in
                            actionRow(action, index: index)
                        }
                    }
                }
                .layoutPriority(1)

                feedbackView
                    .frame(height: 24, alignment: .leading)

                HStack {
                    Text("Tab/↑↓ 选择  •  Enter/空格执行  •  Esc 关闭")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                    Spacer()
                    Button("激活窗口", action: onActivate)
                    Button("关闭", action: onDismiss)
                }
            }
            .padding(DesignTokens.Panel.padding)
        }
        .frame(width: ActionPanelLayoutMetrics.width, height: panelHeight)
        .background(ActionPanelKeyEventHandler(
            onNext: { moveSelection(by: 1) },
            onPrevious: { moveSelection(by: -1) },
            onConfirm: executeSelected,
            onCommand: execute,
            hotKeyConfig: hotKeyConfig,
            onDismiss: onDismiss
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("窗口布局面板")
        .accessibilityHint("使用 Tab 或方向键选择布局，按 Enter 执行，按 Escape 关闭")
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(nsImage: window.appIcon)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName)
                    .font(.system(size: 15, weight: .semibold))
                Text(window.windowTitle.isEmpty ? "未命名窗口" : window.windowTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer()
            Text("窗口布局")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
        }
    }

    private func actionRow(_ action: WindowLayoutActionDescriptor, index: Int) -> some View {
        Button {
            selectedIndex = index
            execute(action.command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbolName)
                    .font(.system(size: 16))
                    .frame(width: 22)
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(hotKeyConfig.chord(for: action.id)?.displayText ?? "未设置")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(index == selectedIndex
                        ? DesignTokens.Colors.accent.opacity(0.22)
                        : DesignTokens.Colors.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(index == selectedIndex ? DesignTokens.Colors.accent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
        .accessibilityHint(index == selectedIndex ? "当前选中，按 Enter 执行" : "调整当前窗口")
    }

    @ViewBuilder
    private var feedbackView: some View {
        if let message = feedback.message {
            HStack(spacing: 6) {
                Image(systemName: feedback.symbolName)
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(feedback.color)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        } else {
            Color.clear
        }
    }

    private func moveSelection(by offset: Int) {
        let count = WindowLayoutActionCatalog.actions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + offset + count) % count
    }

    private func executeSelected() {
        guard WindowLayoutActionCatalog.actions.indices.contains(selectedIndex) else { return }
        execute(WindowLayoutActionCatalog.actions[selectedIndex].command)
    }

    private func execute(_ command: WindowLayoutCommand) {
        feedback = ActionPanelFeedback(result: layoutService.execute(command, for: window))
    }
}

private extension ActionPanelFeedback {
    var symbolName: String {
        switch self {
        case .idle: return ""
        case .success: return "checkmark.circle.fill"
        case .constrained: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle, .success: return .green
        case .constrained: return .orange
        case .failure: return .red
        }
    }
}

private struct ActionPanelKeyEventHandler: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onConfirm: () -> Void
    let onCommand: (WindowLayoutCommand) -> Void
    let hotKeyConfig: WindowLayoutHotKeyConfig
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> ActionPanelKeyCatchView {
        let view = ActionPanelKeyCatchView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ActionPanelKeyCatchView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ActionPanelKeyCatchView) {
        view.onNext = onNext
        view.onPrevious = onPrevious
        view.onConfirm = onConfirm
        view.onCommand = onCommand
        view.hotKeyConfig = hotKeyConfig
        view.onDismiss = onDismiss
    }
}

private final class ActionPanelKeyCatchView: NSView {
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCommand: ((WindowLayoutCommand) -> Void)?
    var hotKeyConfig = WindowLayoutHotKeyConfig()
    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let action = WindowLayoutActionCatalog.actions.first(where: {
            hotKeyConfig.chord(for: $0.id)?.matches(event) == true
        }) {
            onCommand?(action.command)
            return
        }
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        if event.specialKey == .tab || event.specialKey == .downArrow {
            event.modifierFlags.contains(.shift) ? onPrevious?() : onNext?()
            return
        }
        if event.specialKey == .upArrow {
            onPrevious?()
            return
        }
        if let key = event.specialKey, [.carriageReturn, .enter, .newline].contains(key) {
            onConfirm?()
            return
        }
        if event.keyCode == 49 {
            onConfirm?()
            return
        }
        super.keyDown(with: event)
    }
}
