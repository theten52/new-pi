import AppKit
import SwiftUI

/// Renders markdown via WKWebView (markdown-it + highlight.js) with throttled streaming updates.
/// Falls back to native AttributedString when the bundle or WebView fails.
struct NewPiMarkdownText: View {
    let content: String
    var flushRendering: Bool

    @State private var webRendererFailed = false
    @State private var webHeight: CGFloat = 44

    var body: some View {
        Group {
            if let rendererScriptURL = NewPiMarkdownWebDocument.rendererScriptURL(), !webRendererFailed {
                NewPiMarkdownWebRendererView(
                    markdown: content,
                    rendererScriptURL: rendererScriptURL,
                    height: $webHeight,
                    flushRendering: flushRendering,
                    onRenderingFailed: {
                        webRendererFailed = true
                    }
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 1,
                    idealHeight: webHeight,
                    maxHeight: webHeight,
                    alignment: .leading
                )
                .accessibilityLabel(content)
            } else {
                nativeFallback
            }
        }
        .onChange(of: content) {
            webHeight = 44
        }
    }

    private var nativeFallback: some View {
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
    var isStreaming = false
    var isActiveStreamingItem = false
    var onFork: ((Int) -> Void)?

    private var isUser: Bool { item.title == "You" }
    private var isAssistantLike: Bool {
        item.title == "NewPi" || item.title == "Summary"
    }

    private var usesMarkdown: Bool {
        item.title == "NewPi" || item.title == "Summary" || item.title.hasPrefix("Tool")
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

                if item.canFork, let index = item.messageIndex, let onFork {
                    Button {
                        onFork(index)
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .buttonStyle(.borderless)
                    .help("Fork from here")
                    .disabled(isStreaming)
                }
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
        if usesMarkdown {
            NewPiMarkdownText(
                content: item.body,
                flushRendering: !isActiveStreamingItem
            )
        } else if item.title == "Error" {
            Text(item.body)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else {
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
