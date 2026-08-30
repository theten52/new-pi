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

/// 用户消息附带的结构化附件（当前仅图片，后续可扩展 file 等）。
/// 图片数据**不内联 base64**，只存相对附件根目录的路径引用，见
/// `SessionAttachments`（`docs/multi-modal-vision-plan.md`）。
public struct MessageAttachment: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case image
    }

    public var kind: Kind
    /// MIME 类型，如 "image/png" / "image/jpeg"。
    public var mediaType: String
    /// 相对附件根目录的路径（不含绝对前缀，可移植）。
    public var path: String
    /// 原始文件名（展示用）。
    public var displayName: String
    /// 附给模型的说明文本（如缩放后的坐标映射提示，`ImageAttachmentProcessor` 生成）；
    /// 序列化时紧跟 image 块以 text 块下发。旧会话缺省 nil（safely synthesized decode
    /// 对 Optional 用 decodeIfPresent）。
    public var note: String?

    public init(
        kind: Kind = .image,
        mediaType: String,
        path: String,
        displayName: String,
        note: String? = nil
    ) {
        self.kind = kind
        self.mediaType = mediaType
        self.path = path
        self.displayName = displayName
        self.note = note
    }
}

public struct UserMessage: Sendable, Codable, Equatable {
    public var content: String
    public var attachments: [MessageAttachment]
    public var timestamp: Date

    public init(content: String, attachments: [MessageAttachment] = [], timestamp: Date = Date()) {
        self.content = content
        self.attachments = attachments
        self.timestamp = timestamp
    }

    /// 向后兼容：旧会话文件没有 `attachments` 字段，缺省为空数组。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try container.decode(String.self, forKey: .content)
        self.attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
    }
}

public struct AssistantMessage: Sendable, Codable, Equatable {
    public var text: String
    /// Provider-specific chain-of-thought (e.g. DeepSeek `reasoning_content`).
    public var reasoningContent: String
    /// Anthropic extended thinking 的签名；回放历史时与 thinking block 一起
    /// 原样带回（无签名的 thinking block 会被 API 拒绝）。
    public var reasoningSignature: String
    public var toolCalls: [ToolCallContent]
    public var provider: String
    public var modelID: String
    public var stopReason: StopReason
    public var usage: UsageStats
    public var timestamp: Date

    public init(
        text: String,
        reasoningContent: String = "",
        reasoningSignature: String = "",
        toolCalls: [ToolCallContent] = [],
        provider: String,
        modelID: String,
        stopReason: StopReason,
        usage: UsageStats = UsageStats(),
        timestamp: Date = Date()
    ) {
        self.text = text
        self.reasoningContent = reasoningContent
        self.reasoningSignature = reasoningSignature
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
        self.reasoningSignature = try container.decodeIfPresent(String.self, forKey: .reasoningSignature) ?? ""
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

    public static func user(_ content: String, attachments: [MessageAttachment]) -> AgentMessage {
        .user(UserMessage(content: content, attachments: attachments))
    }
}
