import Foundation

public struct CompactionService: Sendable {
    private static let summarizationSystemPrompt = """
    You summarize prior coding-agent conversation history for context compaction.
    Preserve decisions, file paths, code changes, errors, and open tasks.
    Be concise but complete. Output plain text only — no markdown headings.
    """

    public init() {}

    public func compactIfNeeded(
        context: inout AgentContext,
        config: AgentLoopConfig,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws {
        let compaction = config.compaction
        guard compaction.enabled else { return }

        let estimatedTokens = ContextTokenEstimator.estimate(
            messages: context.messages,
            systemPrompt: context.systemPrompt
        )
        guard estimatedTokens >= compaction.triggerTokenCount else { return }

        guard let (toCompact, toKeep) = Self.partition(
            messages: context.messages,
            keepRecent: compaction.keepRecentMessages
        ) else {
            return
        }

        let summary = try await Self.summarize(
            messages: toCompact,
            model: config.model,
            llm: config.llm
        )
        guard !summary.isEmpty else { return }

        let summaryMessage = AgentMessage.compactionSummary(summary)
        continuation.yield(.messageStart(summaryMessage))
        context.messages = [summaryMessage] + toKeep
        continuation.yield(.messageEnd(summaryMessage))
    }

    static func partition(
        messages: [AgentMessage],
        keepRecent: Int
    ) -> (toCompact: [AgentMessage], toKeep: [AgentMessage])? {
        guard messages.count > keepRecent else { return nil }

        var splitIndex = messages.count - keepRecent
        while splitIndex > 0, case .toolResult = messages[splitIndex] {
            splitIndex -= 1
        }
        guard splitIndex > 0 else { return nil }

        return (
            Array(messages[..<splitIndex]),
            Array(messages[splitIndex...])
        )
    }

    static func summarize(
        messages: [AgentMessage],
        model: ModelConfig,
        llm: any LLMProvider
    ) async throws -> String {
        let body = render(messages: messages)
        let prompt = AgentMessage.user(
            """
            Summarize the conversation below for continuation by a coding agent.

            \(body)
            """
        )

        var summary = ""
        for try await event in llm.stream(
            model: model,
            systemPrompt: summarizationSystemPrompt,
            messages: [prompt],
            tools: []
        ) {
            switch event {
            case let .textDelta(delta):
                summary += delta
            case .completed:
                break
            case .thinkingDelta, .toolCall:
                continue
            }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func render(messages: [AgentMessage]) -> String {
        messages.map { message -> String in
            switch message {
            case let .user(user):
                return "[user] \(user.content)"
            case let .assistant(assistant):
                var lines = ["[assistant] \(assistant.text)"]
                for call in assistant.toolCalls {
                    lines.append("[tool_call] \(call.name)(\(call.arguments))")
                }
                return lines.joined(separator: "\n")
            case let .toolResult(result):
                return "[tool:\(result.toolName)] \(result.content)"
            case let .compactionSummary(summary):
                return "[prior_summary] \(summary)"
            }
        }
        .joined(separator: "\n\n")
    }
}
