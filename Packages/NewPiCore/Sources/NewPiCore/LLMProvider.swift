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

extension URLSession {
    /// NewPi 流式请求的默认 session。URLSession.shared 的 resource timeout 默认
    /// 长达 7 天：SSE 服务端挂起（连接不断但不再发字节）时流式请求会永久卡住。
    /// 这里给请求/资源级超时一个合理上限（流式响应可能持续较久，resource
    /// timeout 取 10 分钟）；需要更长超时的调用方可注入自定义 session。
    public static let newPiDefault: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
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
