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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            messageBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var messageBody: some View {
        switch item.title {
        case "NewPi", "Summary":
            NewPiMarkdownText(content: item.body)
        case _ where item.title.hasPrefix("Tool "):
            Text(item.body)
                .font(.body.monospaced())
                .textSelection(.enabled)
        default:
            Text(item.body)
                .textSelection(.enabled)
        }
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
    .frame(width: 420)
}
