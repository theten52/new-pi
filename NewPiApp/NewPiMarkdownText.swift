import AppKit
import SwiftUI

/// Renders assistant-style markdown in the transcript; tolerates partial input while streaming.
struct NewPiMarkdownText: View {
    let content: String

    var body: some View {
        Group {
            if let attributed = parsedMarkdown {
                Text(attributed)
            } else {
                Text(content)
            }
        }
        .textSelection(.enabled)
        .lineSpacing(3)
    }

    private var parsedMarkdown: AttributedString? {
        try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )
    }
}

struct NewPiTranscriptRow: View {
    let item: NewPiTranscriptItem

    private var isUser: Bool { item.title == "You" }
    private var isAssistantLike: Bool {
        item.title == "NewPi" || item.title == "Summary"
    }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 72)
                bubble
            } else {
                bubble
                Spacer(minLength: 72)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    copyBody()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy message")
            }

            messageBody
        }
        .padding(12)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 640, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageBody: some View {
        switch item.title {
        case "NewPi", "Summary":
            NewPiMarkdownText(content: item.body)
        case "Error":
            Text(item.body)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case _ where item.title.hasPrefix("Tool"):
            Text(item.body)
                .font(.body.monospaced())
                .textSelection(.enabled)
        default:
            Text(item.body)
                .textSelection(.enabled)
        }
    }

    private var bubbleBackground: Color {
        if item.title == "Error" {
            return Color.red.opacity(0.08)
        }
        if isUser {
            return Color.accentColor.opacity(0.16)
        }
        if isAssistantLike {
            return Color(nsColor: .controlBackgroundColor)
        }
        return Color(nsColor: .windowBackgroundColor)
    }

    private func copyBody() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.body, forType: .string)
    }
}

struct NewPiChatEmptyStateView: View {
    var hasProject: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(hasProject ? "Start a session" : "Open a project")
                .font(.title3.weight(.semibold))
            Text(hasProject
                ? "Ask NewPi to read, edit, or run commands in your project. Sessions are saved automatically."
                : "Choose a project folder to load AGENTS.md, skills, and saved sessions.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding()
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        NewPiTranscriptRow(item: NewPiTranscriptItem(
            title: "NewPi",
            body: "**Bold** and `code`\n\n```swift\nprint(\"hi\")\n```"
        ))
        NewPiTranscriptRow(item: NewPiTranscriptItem(title: "You", body: "Plain user text"))
    }
    .padding()
    .frame(width: 520)
}
