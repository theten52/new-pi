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
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum StopReason: String, Sendable, Codable {
    case stop
    case toolUse
    case length
    case error
    case aborted
}
