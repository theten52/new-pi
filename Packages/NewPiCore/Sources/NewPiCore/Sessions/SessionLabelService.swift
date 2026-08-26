import Foundation

public struct SessionLabelService: Sendable {
    private static let systemPrompt = """
    You generate short titles for coding-agent chat sessions.
    Output a concise title in Simplified Chinese (简体中文), at most 12 characters when possible.
    No quotes, no punctuation at the end, plain text only.
    """

    public init() {}

    public static func firstExchange(from messages: [AgentMessage]) -> (user: String, assistant: String)? {
        var userText: String?
        var assistantText: String?

        for message in messages {
            switch message {
            case let .user(user):
                if userText == nil {
                    userText = user.content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case let .assistant(assistant):
                if userText != nil, assistantText == nil {
                    let text = assistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        assistantText = text
                    }
                }
            case .toolResult, .compactionSummary:
                continue
            }
            if userText != nil, assistantText != nil {
                break
            }
        }

        guard let userText, !userText.isEmpty,
              let assistantText, !assistantText.isEmpty else {
            return nil
        }
        return (userText, assistantText)
    }

    public static func generateLabel(
        userMessage: String,
        assistantMessage: String,
        model: ModelConfig,
        llm: any LLMProvider
    ) async throws -> String {
        let prompt = AgentMessage.user(
            """
            Write a short session title based on this opening exchange.

            [user]
            \(userMessage)

            [assistant]
            \(NewPiLogFormat.truncate(assistantMessage, maxLength: 1500))
            """
        )

        var title = ""
        for try await event in llm.stream(
            model: model,
            systemPrompt: systemPrompt,
            messages: [prompt],
            tools: []
        ) {
            switch event {
            case let .textDelta(delta):
                title += delta
            case .completed:
                break
            case .thinkingDelta, .toolCall:
                continue
            }
        }

        return sanitize(title)
    }

    static func sanitize(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("\""), title.hasSuffix("\""), title.count >= 2 {
            title = String(title.dropFirst().dropLast())
        }
        if title.count > 40 {
            title = String(title.prefix(40))
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
