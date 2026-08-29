import Foundation

public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd
    case turnStart
    case turnEnd
    case messageStart(AgentMessage)
    case textDelta(String)
    case thinkingDelta(String)
    case toolExecutionStart(id: String, name: String, arguments: JSONValue)
    case toolApprovalRequired(ToolApprovalRequest)
    case toolExecutionUpdate(id: String, message: String)
    case toolExecutionEnd(id: String, name: String, result: ToolResult)
    case messageEnd(AgentMessage)
    case contextSnapshot(AgentContext)
    case error(AgentError)

    /// 事件名（不含负载），供诊断日志使用。
    public var diagnosticName: String {
        switch self {
        case .agentStart: "agentStart"
        case .agentEnd: "agentEnd"
        case .turnStart: "turnStart"
        case .turnEnd: "turnEnd"
        case .messageStart: "messageStart"
        case .textDelta: "textDelta"
        case .thinkingDelta: "thinkingDelta"
        case .toolExecutionStart: "toolExecutionStart"
        case .toolApprovalRequired: "toolApprovalRequired"
        case .toolExecutionUpdate: "toolExecutionUpdate"
        case .toolExecutionEnd: "toolExecutionEnd"
        case .messageEnd: "messageEnd"
        case .contextSnapshot: "contextSnapshot"
        case .error: "error"
        }
    }
}

public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public struct ToolProgress: Sendable, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public enum AgentError: Error, Sendable, Equatable {
    case aborted
    case toolNotFound(String)
    case toolBlocked(reason: String)
    case llmFailed(String)
    case invalidState(String)
}

extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .aborted:
            "Agent run was aborted."
        case let .toolNotFound(name):
            "Tool not found: \(name)"
        case let .toolBlocked(reason):
            "Tool blocked: \(reason)"
        case let .llmFailed(message):
            "LLM request failed: \(message)"
        case let .invalidState(message):
            "Invalid agent state: \(message)"
        }
    }
}
