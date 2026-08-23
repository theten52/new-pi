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
    public var toolPolicy: ToolPolicyRules
    public var compaction: CompactionConfig
    public var beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)?
    public var requestToolApproval: (@Sendable (ToolApprovalRequest) async -> Bool)?

    public init(
        model: ModelConfig,
        llm: any LLMProvider,
        tools: [any AgentTool] = [],
        toolExecution: ToolExecutionMode = .parallel,
        toolPolicy: ToolPolicyRules = .codingAgentDefault,
        compaction: CompactionConfig = CompactionConfig(),
        beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)? = nil,
        requestToolApproval: (@Sendable (ToolApprovalRequest) async -> Bool)? = nil
    ) {
        self.model = model
        self.llm = llm
        self.tools = tools
        self.toolExecution = toolExecution
        self.toolPolicy = toolPolicy
        self.compaction = compaction
        self.beforeToolCall = beforeToolCall
        self.requestToolApproval = requestToolApproval
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
