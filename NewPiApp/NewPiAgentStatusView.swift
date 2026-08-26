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

    var frame: CGFloat {
        switch self {
        case .toolbar: 36
        case .bar: 30
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .toolbar: 18
        case .bar: 16
        }
    }
}

struct NewPiAgentStatusIcon: View {
    let presentation: NewPiAgentStatusPresentation
    var size: NewPiAgentStatusIconSize = .toolbar

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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
struct NewPiAgentStatusBar: View {
    let presentation: NewPiAgentStatusPresentation

    var body: some View {
        HStack(spacing: 10) {
            NewPiAgentStatusIcon(presentation: presentation, size: .bar)
            Text(presentation.label)
                .font(.subheadline)
                .foregroundStyle(presentation.isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.label)
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
