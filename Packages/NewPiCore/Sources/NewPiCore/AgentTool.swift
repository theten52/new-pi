import Foundation

public struct ToolContext: Sendable {
    public var workingDirectory: URL
    public var environment: [String: String]
    /// 工具的审批/危险评估链路（由 AgentLoop 从 config 透传）。
    /// 需要派生子代理的工具（如 SubAgentTool）应把它继续传给子代理的
    /// AgentLoopConfig，确保子代理的副作用工具同样受策略约束。
    public var toolPolicy: ToolPolicyRules
    public var beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)?
    public var requestToolApproval: (@Sendable (ToolApprovalRequest) async -> ApprovalDecision)?
    public var toolApprovalTracker: ToolApprovalTracker?
    public var dangerEvaluator: DangerEvaluator?
    public var dangerCache: DangerAssessmentCache?
    /// 审批审计日志：每次工具调用记录原始参数/危险评估/审批路径与结果。
    public var auditLogger: ToolApprovalAuditLogger?

    public init(
        workingDirectory: URL,
        environment: [String: String] = [:],
        toolPolicy: ToolPolicyRules = .codingAgentDefault,
        beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)? = nil,
        requestToolApproval: (@Sendable (ToolApprovalRequest) async -> ApprovalDecision)? = nil,
        toolApprovalTracker: ToolApprovalTracker? = nil,
        dangerEvaluator: DangerEvaluator? = nil,
        dangerCache: DangerAssessmentCache? = nil,
        auditLogger: ToolApprovalAuditLogger? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.toolPolicy = toolPolicy
        self.beforeToolCall = beforeToolCall
        self.requestToolApproval = requestToolApproval
        self.toolApprovalTracker = toolApprovalTracker
        self.dangerEvaluator = dangerEvaluator
        self.dangerCache = dangerCache
        self.auditLogger = auditLogger
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
    /// Upper bound on LLM↔tool round-trips per user prompt (safety valve against runaway loops).
    public static let defaultMaxTurns = 200

    public var model: ModelConfig
    public var llm: any LLMProvider
    public var tools: [any AgentTool]
    public var toolExecution: ToolExecutionMode
    public var toolPolicy: ToolPolicyRules
    public var compaction: CompactionConfig
    public var maxTurns: Int
    public var beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)?
    public var requestToolApproval: (@Sendable (ToolApprovalRequest) async -> ApprovalDecision)?
    /// Session-scoped tracker of tools already approved by the user.
    /// When a tool is present in the tracker, no approval is required for
    /// subsequent calls to the same tool within the same session.
    public var toolApprovalTracker: ToolApprovalTracker?
    /// 危险评估器：本地规则为主 + LLM 可选补充 + 缓存。
    public var dangerEvaluator: DangerEvaluator?
    /// 危险评估结果缓存（跨调用复用）。
    public var dangerCache: DangerAssessmentCache?
    /// 审批审计日志：每次工具调用记录原始参数/危险评估/审批路径与结果。
    public var auditLogger: ToolApprovalAuditLogger?

    public init(
        model: ModelConfig,
        llm: any LLMProvider,
        tools: [any AgentTool] = [],
        toolExecution: ToolExecutionMode = .parallel,
        toolPolicy: ToolPolicyRules = .codingAgentDefault,
        compaction: CompactionConfig = CompactionConfig(),
        maxTurns: Int = AgentLoopConfig.defaultMaxTurns,
        beforeToolCall: (@Sendable (String, JSONValue) async -> BeforeToolCallDecision)? = nil,
        requestToolApproval: (@Sendable (ToolApprovalRequest) async -> ApprovalDecision)? = nil,
        toolApprovalTracker: ToolApprovalTracker? = nil,
        dangerEvaluator: DangerEvaluator? = nil,
        dangerCache: DangerAssessmentCache? = nil,
        auditLogger: ToolApprovalAuditLogger? = nil
    ) {
        self.model = model
        self.llm = llm
        self.tools = tools
        self.toolExecution = toolExecution
        self.toolPolicy = toolPolicy
        self.compaction = compaction
        self.maxTurns = max(1, maxTurns)
        self.beforeToolCall = beforeToolCall
        self.requestToolApproval = requestToolApproval
        self.toolApprovalTracker = toolApprovalTracker
        self.dangerEvaluator = dangerEvaluator
        self.dangerCache = dangerCache
        self.auditLogger = auditLogger
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
