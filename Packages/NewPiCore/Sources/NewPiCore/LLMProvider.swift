import Foundation

public enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCall(ToolCallContent)
    case completed(stopReason: StopReason, usage: UsageStats)
}

public struct LLMMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case toolResult
    }

    public var role: Role
    public var content: String
    public var toolCallID: String?
    public var toolName: String?

    public init(role: Role, content: String, toolCallID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

public protocol LLMProvider: Sendable {
    func stream(
        model: ModelConfig,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public enum LLMMessageConverter {
    /// Legacy flat representation for providers that do not consume structured history.
    public static func convert(_ messages: [AgentMessage]) -> [LLMMessage] {
        messages.flatMap { message -> [LLMMessage] in
            switch message {
            case let .user(user):
                return [LLMMessage(role: .user, content: user.content)]
            case let .assistant(assistant):
                var result = [LLMMessage(role: .assistant, content: assistant.text)]
                if !assistant.toolCalls.isEmpty {
                    let toolSummary = assistant.toolCalls
                        .map { call in
                            "[tool_call id=\(call.id) name=\(call.name) args=\(String(describing: call.arguments))]"
                        }
                        .joined(separator: "\n")
                    result = [LLMMessage(role: .assistant, content: assistant.text + "\n" + toolSummary)]
                }
                return result
            case let .toolResult(toolResult):
                return [LLMMessage(
                    role: .toolResult,
                    content: toolResult.content,
                    toolCallID: toolResult.toolCallID,
                    toolName: toolResult.toolName
                )]
            case let .compactionSummary(summary):
                return [LLMMessage(role: .user, content: "Conversation summary:\n\(summary)")]
            }
        }
    }
}
