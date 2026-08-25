import Foundation

public enum SessionExportFormat: String, Sendable, CaseIterable {
    case markdown
    case json
    case text
}

public struct SessionExporter: Sendable {
    public init() {}

    public func exportMarkdown(
        context: SessionContext,
        messages: [AgentMessage],
        leafID: String? = nil
    ) -> String {
        var lines = [
            "# NewPi Session",
            "",
            "- **Session ID:** \(context.header.id.uuidString)",
            "- **Project:** `\(context.header.workingDirectory.path)`",
            "- **Created:** \(context.header.createdAt.formatted())",
        ]

        if let label = context.header.label {
            lines.append("- **Label:** \(label)")
        }
        if let provider = context.header.providerProfileID {
            lines.append("- **Provider:** \(provider)")
        }
        if let model = context.header.modelID {
            lines.append("- **Model:** \(model)")
        }
        if let leafID {
            lines.append("- **Branch leaf:** \(leafID)")
        }

        lines.append("")
        lines.append("---")
        lines.append("")

        for message in messages {
            lines.append(renderMarkdown(message))
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    public func exportText(messages: [AgentMessage]) -> String {
        messages.map { renderPlain($0) }.joined(separator: "\n\n")
    }

    public func exportJSON(context: SessionContext) throws -> Data {
        try JSONLSessionCodec().encode(context)
    }

    public func exportTranscriptMarkdown(items: [(title: String, body: String)]) -> String {
        var lines = ["# NewPi Transcript", ""]
        for item in items {
            lines.append("## \(item.title)")
            lines.append("")
            lines.append(item.body)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private func renderMarkdown(_ message: AgentMessage) -> String {
        switch message {
        case let .user(user):
            return "### You\n\n\(user.content)"
        case let .assistant(assistant):
            var text = "### NewPi\n\n\(assistant.text)"
            if !assistant.toolCalls.isEmpty {
                let names = assistant.toolCalls.map(\.name).joined(separator: ", ")
                text += "\n\n_Tools requested: \(names)_"
            }
            return text
        case let .toolResult(result):
            let fence = result.content.contains("```") ? "````" : "```"
            let status = result.isError ? " (error)" : ""
            return "### Tool: \(result.toolName)\(status)\n\n\(fence)\n\(result.content)\n\(fence)"
        case let .compactionSummary(summary):
            return "### Summary\n\n\(summary)"
        }
    }

    private func renderPlain(_ message: AgentMessage) -> String {
        switch message {
        case let .user(user):
            return "You: \(user.content)"
        case let .assistant(assistant):
            return "NewPi: \(assistant.text)"
        case let .toolResult(result):
            let prefix = result.isError ? "Tool (error)" : "Tool"
            return "\(prefix) \(result.toolName): \(result.content)"
        case let .compactionSummary(summary):
            return "Summary: \(summary)"
        }
    }
}
