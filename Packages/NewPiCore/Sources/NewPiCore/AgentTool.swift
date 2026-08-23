import Foundation

public struct ToolContext: Sendable {
    public var workingDirectory: URL
    public var environment: [String: String]

    public init(workingDirectory: URL, environment: [String: String] = [:]) {
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var definition: ToolDefinition { get }

    func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult
}

public enum ToolExecutionMode: Sendable {
    case parallel
    case sequential
}

public struct BeforeToolCallDecision: Sendable, Equatable {
    public var block: Bool
    public var reason: String?

    public init(block: Bool = false, reason: String? = nil) {
        self.block = block
        self.reason = reason
    }
}

public struct AgentLoopConfig: Sendable {
    public var model: ModelConfig
    public var llm: any LLMProvider
    public var tools: [any AgentTool]
    public var toolExecution: ToolExecutionMode
    public var beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)?

    public init(
        model: ModelConfig,
        llm: any LLMProvider,
        tools: [any AgentTool] = [],
        toolExecution: ToolExecutionMode = .parallel,
        beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)? = nil
    ) {
        self.model = model
        self.llm = llm
        self.tools = tools
        self.toolExecution = toolExecution
        self.beforeToolCall = beforeToolCall
    }
}

public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [AgentMessage]
    public var workingDirectory: URL

    public init(
        systemPrompt: String,
        messages: [AgentMessage] = [],
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.workingDirectory = workingDirectory
    }
}
