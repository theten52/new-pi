import NewPiCore
import SwiftUI

struct NewPiAgentStatusPresentation: Equatable {
    let systemImage: String
    let label: String
    let isActive: Bool

    static func toolIcon(for toolName: String) -> String {
        switch toolName {
        case "bash":
            "terminal"
        case "read":
            "doc.text.magnifyingglass"
        case "write":
            "square.and.pencil"
        case "edit":
            "pencil.line"
        case "subagent":
            "person.2.circle"
        default:
            "wrench.and.screwdriver"
        }
    }
}

enum NewPiAgentStatusIconSize {
    case toolbar
    case bar
    /// 与状态栏文本高度一致的紧凑尺寸。
    case compact

    var frame: CGFloat {
        switch self {
        case .toolbar: 36
        case .bar: 30
        case .compact: 18
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .toolbar: 18
        case .bar: 16
        case .compact: 11
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .toolbar, .bar: 8
        case .compact: 5
        }
    }
}

struct NewPiAgentStatusIcon: View {
    let presentation: NewPiAgentStatusPresentation
    var size: NewPiAgentStatusIconSize = .toolbar

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }
                .frame(width: size.frame, height: size.frame)

            Image(systemName: presentation.systemImage)
                .font(.system(size: size.symbolSize, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .symbolEffect(.pulse, isActive: presentation.isActive)
        }
        .accessibilityHidden(true)
    }

    private var backgroundColor: Color {
        if presentation.isActive {
            return Color.accentColor.opacity(0.12)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if presentation.isActive {
            return Color.accentColor.opacity(0.28)
        }
        return Color.primary.opacity(0.08)
    }

    private var foregroundColor: Color {
        if pendingApproval {
            return .orange
        }
        return presentation.isActive ? Color.accentColor : .secondary
    }

    private var pendingApproval: Bool {
        presentation.systemImage == "hand.raised.circle"
    }
}

/// Input-area status strip — always visible above the composer.
/// 输入框上方状态栏基座：左侧 agent 状态，右侧本会话 token 用量（BACKLOG-TOKEN-BAR）。
struct NewPiAgentStatusBar: View {
    let presentation: NewPiAgentStatusPresentation
    /// 累计用量文本（如 "↑12.3k ↓4.5k"）；nil 时隐藏。
    var usageText: String? = nil
    /// 最近一轮用量文本，用于 tooltip 明细。
    var lastTurnUsageText: String? = nil
    /// 缓存命中率文本（如 "85%"）；nil 时隐藏。
    var cacheHitRateText: String? = nil

    var body: some View {
        // 图标用与文本同高的紧凑尺寸；整条用与输入框一致的圆角矩形包裹
        //（宽度由调用方 .padding(.horizontal) 控制，与输入框对齐）。
        HStack(spacing: 8) {
            NewPiAgentStatusIcon(presentation: presentation, size: .compact)
            Text(presentation.label)
                .font(.subheadline)
                .foregroundStyle(presentation.isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let cacheHitRateText {
                Label(cacheHitRateText, systemImage: "bolt.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("本会话累计缓存命中率（命中缓存的输入 token / 总输入 token）")
            }
            if let usageText {
                Text(usageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(
                        lastTurnUsageText.map {
                            "本会话累计 token 用量（↑ 输入 / ↓ 输出）\n最近一轮：\($0)"
                        } ?? "本会话累计 token 用量（↑ 输入 / ↓ 输出）"
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // 高亮：与输入框一致的淡 accent 填充 + 描边，让状态栏/输入框区域更显眼。
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.label)
    }
}

extension UsageStats {
    /// 紧凑用量文本（如 "↑12.3k ↓456"）；为零时返回 nil（不显示）。
    var newPiCompactText: String? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return "↑\(Self.newPiCompact(inputTokens)) ↓\(Self.newPiCompact(outputTokens))"
    }

    private static func newPiCompact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    /// 缓存命中率文本（如 "85%"）；无缓存命中时返回 nil（不显示）。
    var newPiCacheHitRateText: String? {
        guard cacheReadTokens > 0, let rate = cacheHitRate else { return nil }
        return String(format: "%.0f%%", rate * 100)
    }
}

#Preview("Ready") {
    NewPiAgentStatusBar(
        presentation: NewPiAgentStatusPresentation(
            systemImage: "checkmark.circle",
            label: "NewPi is ready",
            isActive: false
        )
    )
    .frame(width: 480)
}

#Preview("Thinking") {
    NewPiAgentStatusBar(
        presentation: NewPiAgentStatusPresentation(
            systemImage: "brain.head.profile",
            label: "NewPi is thinking…",
            isActive: true
        )
    )
    .frame(width: 480)
}
