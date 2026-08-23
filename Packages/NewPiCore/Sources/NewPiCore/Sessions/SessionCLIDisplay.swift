import Foundation

public enum SessionCLIDisplay {
    public static func formatList(_ summaries: [SessionSummary], projectURL: URL) -> String {
        var lines = [
            "Sessions for \(projectURL.path)",
            "Project hash: \(SessionManager.projectHash(for: projectURL))",
            "",
        ]

        if summaries.isEmpty {
            lines.append("(no sessions)")
            return lines.joined(separator: "\n")
        }

        lines.append("ID          Created                   Msgs  Model")
        for summary in summaries {
            let shortID = String(summary.id.uuidString.prefix(8)).lowercased()
            let created = summary.createdAt.formatted(date: .abbreviated, time: .shortened)
            let label = summary.label.map { " \($0)" } ?? ""
            let model = summary.modelID ?? "-"
            lines.append("\(shortID.padding(toLength: 10, withPad: " ", startingAt: 0))  \(created.padding(toLength: 24, withPad: " ", startingAt: 0))  \(String(format: "%5d", summary.messageCount))  \(model)\(label)")
        }
        return lines.joined(separator: "\n")
    }

    public static func formatShow(
        context: SessionContext,
        messages: [AgentMessage],
        fileURL: URL
    ) -> String {
        var lines = [
            "Session \(context.header.id.uuidString)",
            "File: \(fileURL.path)",
            "Project: \(context.header.workingDirectory.path)",
            "Created: \(context.header.createdAt.formatted())",
        ]

        if let label = context.header.label {
            lines.append("Label: \(label)")
        }
        if let provider = context.header.providerProfileID {
            lines.append("Provider: \(provider)")
        }
        if let model = context.header.modelID {
            lines.append("Model: \(model)")
        }

        lines.append("")
        lines.append("Messages (\(messages.count)):")
        lines.append("")

        for (index, message) in messages.enumerated() {
            lines.append("[\(index + 1)] \(render(message))")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func render(_ message: AgentMessage) -> String {
        switch message {
        case let .user(user):
            return "user: \(user.content)"
        case let .assistant(assistant):
            var text = "assistant: \(assistant.text)"
            if !assistant.toolCalls.isEmpty {
                let names = assistant.toolCalls.map(\.name).joined(separator: ", ")
                text += "\n  tools: \(names)"
            }
            return text
        case let .toolResult(result):
            let prefix = result.isError ? "tool (error)" : "tool"
            return "\(prefix) \(result.toolName): \(result.content)"
        case let .compactionSummary(summary):
            return "summary: \(summary)"
        }
    }
}
