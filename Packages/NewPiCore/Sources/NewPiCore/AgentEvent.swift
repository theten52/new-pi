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

public struct ToolResult: Sendable, Codable, Equatable {
    public var content: String
    public var isError: Bool
    /// 仅本次工具实际写入的文件记录，不是工作区差异。
    public var fileChanges: [ToolFileChange]
    /// 单调时钟测得的执行耗时；未执行/未知为 nil，不含审批等待。
    public var durationSeconds: Double?
    public var progressReport: ProgressReport?
    public var testReport: TestReport?

    public init(content: String, isError: Bool = false, fileChanges: [ToolFileChange] = [],
                durationSeconds: Double? = nil, progressReport: ProgressReport? = nil,
                testReport: TestReport? = nil) {
        self.content = content
        self.isError = isError
        self.fileChanges = fileChanges
        self.durationSeconds = durationSeconds
        self.progressReport = progressReport
        self.testReport = testReport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        fileChanges = try container.decodeIfPresent([ToolFileChange].self, forKey: .fileChanges) ?? []
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        progressReport = try container.decodeIfPresent(ProgressReport.self, forKey: .progressReport)
        testReport = try container.decodeIfPresent(TestReport.self, forKey: .testReport)
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
