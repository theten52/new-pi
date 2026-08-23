import Foundation

public enum ContextTokenEstimator {
    /// Rough token estimate (~4 characters per token) for compaction heuristics.
    public static func estimate(messages: [AgentMessage], systemPrompt: String) -> Int {
        let systemTokens = estimateText(systemPrompt)
        let messageTokens = messages.reduce(into: 0) { total, message in
            total += estimate(message)
        }
        return systemTokens + messageTokens
    }

    public static func estimate(_ message: AgentMessage) -> Int {
        switch message {
        case let .user(user):
            estimateText(user.content) + 4
        case let .assistant(assistant):
            estimateText(assistant.text)
                + assistant.toolCalls.reduce(into: 0) { total, call in
                    total += estimateText(call.name)
                    total += estimateText(String(describing: call.arguments))
                }
                + 8
        case let .toolResult(result):
            estimateText(result.content) + estimateText(result.toolName) + 6
        case let .compactionSummary(summary):
            estimateText(summary) + 4
        }
    }

    private static func estimateText(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
