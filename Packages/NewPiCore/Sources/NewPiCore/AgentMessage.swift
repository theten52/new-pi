import Foundation

public struct TextContent: Sendable, Codable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ToolCallContent: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct UserMessage: Sendable, Codable, Equatable {
    public var content: String
    public var timestamp: Date

    public init(content: String, timestamp: Date = Date()) {
        self.content = content
        self.timestamp = timestamp
    }
}

public struct AssistantMessage: Sendable, Codable, Equatable {
    public var text: String
    /// Provider-specific chain-of-thought (e.g. DeepSeek `reasoning_content`).
    public var reasoningContent: String
    public var toolCalls: [ToolCallContent]
    public var provider: String
    public var modelID: String
    public var stopReason: StopReason
    public var usage: UsageStats
    public var timestamp: Date

    public init(
        text: String,
        reasoningContent: String = "",
        toolCalls: [ToolCallContent] = [],
        provider: String,
        modelID: String,
        stopReason: StopReason,
        usage: UsageStats = UsageStats(),
        timestamp: Date = Date()
    ) {
        self.text = text
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.provider = provider
        self.modelID = modelID
        self.stopReason = stopReason
        self.usage = usage
        self.timestamp = timestamp
    }

    /// Tolerant decoder for backwards compatibility with older session files
    /// written before `reasoningContent` (and other optional fields) existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent) ?? ""
        self.toolCalls = try container.decodeIfPresent([ToolCallContent].self, forKey: .toolCalls) ?? []
        self.provider = try container.decode(String.self, forKey: .provider)
        self.modelID = try container.decode(String.self, forKey: .modelID)
        self.stopReason = try container.decode(StopReason.self, forKey: .stopReason)
        self.usage = try container.decodeIfPresent(UsageStats.self, forKey: .usage) ?? UsageStats()
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
    }
}

public struct ToolResultMessage: Sendable, Codable, Equatable {
    public var toolCallID: String
    public var toolName: String
    public var content: String
    public var isError: Bool
    public var timestamp: Date

    public init(
        toolCallID: String,
        toolName: String,
        content: String,
        isError: Bool,
        timestamp: Date = Date()
    ) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.content = content
        self.isError = isError
        self.timestamp = timestamp
    }
}

public enum AgentMessage: Sendable, Codable, Equatable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case compactionSummary(String)

    public var roleLabel: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .toolResult: "toolResult"
        case .compactionSummary: "compactionSummary"
        }
    }
}

extension AgentMessage {
    public static func user(_ content: String) -> AgentMessage {
        .user(UserMessage(content: content))
    }
}
