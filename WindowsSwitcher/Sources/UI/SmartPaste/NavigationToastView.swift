import SwiftUI

/// 智能目录粘贴的提示。
struct NavigationToastView: View {

    enum Style {
        case warning
        case info

        var icon: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "arrow.down.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .warning: return .orange
            case .info: return .blue
            }
        }
    }

    let message: String
    var style: Style = .warning

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: style.icon)
                .foregroundStyle(style.tint)

            Text(message)
                .font(FontSystem.bodySmall)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.button)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.96))
                .shadow(radius: 8, y: 2)
        }
    }
}
