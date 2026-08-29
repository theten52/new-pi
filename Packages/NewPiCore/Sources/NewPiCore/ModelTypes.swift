import Foundation

public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

public enum ThinkingLevel: String, Sendable, Codable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
}

public struct ModelConfig: Sendable, Codable, Equatable {
    public var provider: String
    public var modelID: String
    public var thinkingLevel: ThinkingLevel
    public var maxTokens: Int

    public init(
        provider: String,
        modelID: String,
        thinkingLevel: ThinkingLevel = .off,
        maxTokens: Int = 8192
    ) {
        self.provider = provider
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
        self.maxTokens = maxTokens
    }
}

public struct ToolDefinition: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct UsageStats: Sendable, Codable, Equatable {
    /// 未命中缓存的输入 token。
    public var inputTokens: Int
    public var outputTokens: Int
    /// 命中缓存的输入 token（cache read）。
    public var cacheReadTokens: Int
    /// 写入缓存的输入 token（cache creation/write）。
    public var cacheCreationTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    /// 自定义解码：旧 JSONL 中的 usage 没有 cache 字段，缺省补 0。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
    }

    /// 总输入 token（未命中 + 命中 + 写缓存）。
    public var totalInputTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// 缓存命中率 = 命中 / 总输入；无输入或无缓存信息时为 nil。
    public var cacheHitRate: Double? {
        let total = totalInputTokens
        guard total > 0 else { return nil }
        return Double(cacheReadTokens) / Double(total)
    }

    /// 累加另一份用量。
    public mutating func add(_ other: UsageStats) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
    }
}

public enum StopReason: String, Sendable, Codable {
    case stop
    case toolUse
    case length
    case error
    case aborted
}
