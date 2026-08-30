import Foundation

public struct ToolApprovalRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var toolName: String
    public var arguments: JSONValue
    public var summary: String
    public var dangerLevel: ToolDangerLevel
    public var dangerReason: String?
    public var parametersFingerprint: String

    public init(
        id: String,
        toolName: String,
        arguments: JSONValue,
        summary: String,
        dangerLevel: ToolDangerLevel = .medium,
        dangerReason: String? = nil,
        parametersFingerprint: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.summary = summary
        self.dangerLevel = dangerLevel
        self.dangerReason = dangerReason
        self.parametersFingerprint = parametersFingerprint ?? ToolApprovalFingerprint.make(arguments: arguments)
    }
}

public enum ToolAuthResult: Sendable, Equatable {
    case allow
    case deny(reason: String)
}

public struct ToolPolicyRules: Sendable, Equatable {
    public var requireApprovalFor: Set<String>

    public init(requireApprovalFor: Set<String>) {
        self.requireApprovalFor = requireApprovalFor
    }

    public static let codingAgentDefault = ToolPolicyRules(
        requireApprovalFor: ["write", "edit", "bash", SubAgentTool.toolName]
    )

    public static let allowAll = ToolPolicyRules(requireApprovalFor: [])

    public func requiresApproval(toolName: String) -> Bool {
        if toolName.hasPrefix(MCPToolName.prefix) {
            return true
        }
        return requireApprovalFor.contains(toolName)
    }
}

public enum ToolApprovalSummary {
    public static func make(toolName: String, arguments: JSONValue) -> String {
        switch toolName {
        case "read":
            let path = ToolArguments.optionalString(arguments, key: "path", aliases: ["file_path", "filePath"]) ?? "?"
            return "Read file: \(path)"
        case "write":
            let path = ToolArguments.optionalString(arguments, key: "path", aliases: ["file_path", "filePath"]) ?? "?"
            let content = arguments.objectValue?["content"]?.stringValue ?? ""
            let preview = String(content.prefix(120))
            return "Write file: \(path)\n\(preview)\(content.count > 120 ? "…" : "")"
        case "edit":
            let path = ToolArguments.optionalString(arguments, key: "path", aliases: ["file_path", "filePath"]) ?? "?"
            let oldText = arguments.objectValue?["old_string"]?.stringValue ?? ""
            let newText = arguments.objectValue?["new_string"]?.stringValue ?? ""
            return """
            Edit file: \(path)
            - \(oldText.prefix(80))\(oldText.count > 80 ? "…" : "")
            + \(newText.prefix(80))\(newText.count > 80 ? "…" : "")
            """
        case "bash":
            let command = ToolArguments.optionalString(arguments, key: "command", aliases: ["cmd", "script"]) ?? "?"
            return "Run command:\n\(command)"
        case SubAgentTool.toolName:
            let task = arguments.objectValue?["task"]?.stringValue ?? "?"
            return "Spawn sub-agent:\n\(task.prefix(200))\(task.count > 200 ? "…" : "")"
        default:
            if toolName.hasPrefix(MCPToolName.prefix), let parsed = MCPToolName.parse(toolName) {
                return "MCP tool \(parsed.serverId)/\(parsed.toolName): \(String(describing: arguments))"
            }
            return "\(toolName): \(String(describing: arguments))"
        }
    }
}

/// Tracks tool approvals across scopes:
/// - `session`: 本对话一直允许（session 生命周期）
/// - `forever`: 跨 Session / APP 重启一直允许（持久化到 ApprovalsStore）
/// 危险等级为 high 的调用不会被写入任何永久记录（只放行本次）。
public actor ToolApprovalTracker {
    private var sessionRecords: [String: ApprovalRecord] = [:]
    private let persistentStore: PersistentApprovalStore

    public init(persistentStore: PersistentApprovalStore = PersistentApprovalStore()) {
        self.persistentStore = persistentStore
    }

    /// 判定是否被已有授权覆盖（含 session / forever）。
    /// 高危调用永远返回 false，即必须重新提示。
    public func isAuthorized(toolName: String, fingerprint: String, dangerLevel: ToolDangerLevel) -> Bool {
        authorizationSource(toolName: toolName, fingerprint: fingerprint, dangerLevel: dangerLevel) != nil
    }

    /// 命中已有授权时返回来源（session / forever），供审计日志记录。
    /// 高危调用永远返回 nil，即必须重新提示。
    public func authorizationSource(
        toolName: String,
        fingerprint: String,
        dangerLevel: ToolDangerLevel
    ) -> ToolApprovalAuditEntry.Authorization? {
        if dangerLevel == .high {
            return nil
        }
        if let record = sessionRecords[toolName],
           record.matches(toolName: toolName, fingerprint: fingerprint) {
            return .sessionRecord
        }
        if persistentStore.isForeverApproved(toolName: toolName, fingerprint: fingerprint) {
            return .foreverRecord
        }
        return nil
    }

    /// 记录一次授权。scope 决定写入哪一层。
    /// - 若为 `once`，仅返回（不写入任何记录，只放行本次）。
    /// - 若为 `session`/`forever`，按**整类工具**记忆（不绑定参数指纹）：用户选择
    ///  「本对话一直允许 bash」后，本对话内 bash 的非高危调用都不再弹窗。
    /// - 若危险等级为 high，也不写入任何记录（强制下次继续提示）。
    public func record(
        scope: ApprovalScope,
        toolName: String,
        fingerprint: String,
        dangerLevel: ToolDangerLevel
    ) {
        guard scope != .once else { return }
        guard dangerLevel != .high else { return }

        // 整类工具授权：fingerprint 置 nil，ApprovalRecord.matches 对任意指纹生效。
        let record = ApprovalRecord(
            toolName: toolName,
            parametersFingerprint: nil,
            scope: scope
        )
        switch scope {
        case .once:
            return
        case .session:
            sessionRecords[toolName] = record
            NewPiLogger.info(
                category: "tool-approval",
                message: "Tool approved for session",
                details: "tool=\(toolName) fingerprint=\(fingerprint)"
            )
        case .forever:
            sessionRecords[toolName] = record
            persistentStore.saveForever(record)
            NewPiLogger.info(
                category: "tool-approval",
                message: "Tool approved forever",
                details: "tool=\(toolName) fingerprint=\(fingerprint)"
            )
        }
    }

    public func reset() {
        sessionRecords.removeAll()
    }
}

/// Waits for UI or test harness to approve/deny a tool call.
/// 审批响应结果：包含工具名、指纹、危险等级，供上层写入授权记录。
public struct ApprovalResponse: Sendable, Equatable {
    public var toolName: String
    public var fingerprint: String
    public var dangerLevel: ToolDangerLevel
    public var decision: ApprovalDecision

    public init(toolName: String, fingerprint: String, dangerLevel: ToolDangerLevel, decision: ApprovalDecision) {
        self.toolName = toolName
        self.fingerprint = fingerprint
        self.dangerLevel = dangerLevel
        self.decision = decision
    }
}

public actor ToolApprovalGate {
    private struct PendingRequest {
        let request: ToolApprovalRequest
        let continuation: CheckedContinuation<ApprovalDecision, Never>
    }

    private var waiters: [String: PendingRequest] = [:]

    public init() {}

    public func wait(for request: ToolApprovalRequest) async -> ApprovalDecision {
        NewPiLogger.debug(
            category: "tool-approval",
            message: "Approval gate waiting",
            details: "requestID=\(request.id) tool=\(request.toolName)"
        )
        return await withCheckedContinuation { continuation in
            waiters[request.id] = PendingRequest(
                request: request,
                continuation: continuation
            )
        }
    }

    @discardableResult
    public func respond(requestID: String, decision: ApprovalDecision) -> ApprovalResponse? {
        guard let pending = waiters.removeValue(forKey: requestID) else {
            NewPiLogger.error(
                category: "tool-approval",
                message: "No waiter for approval response",
                details: "requestID=\(requestID)"
            )
            return nil
        }
        NewPiLogger.info(
            category: "tool-approval",
            message: "Approval gate response",
            details: "requestID=\(requestID) approved=\(decision.approved) scope=\(decision.scope) tool=\(pending.request.toolName) pendingWaiters=\(waiters.keys.sorted())"
        )
        pending.continuation.resume(returning: decision)
        return ApprovalResponse(
            toolName: pending.request.toolName,
            fingerprint: pending.request.parametersFingerprint,
            dangerLevel: pending.request.dangerLevel,
            decision: decision
        )
    }

    public func cancelAll() {
        NewPiLogger.info(
            category: "tool-approval",
            message: "Approval gate cancelled all pending requests",
            details: "count=\(waiters.count)"
        )
        for (_, pending) in waiters {
            pending.continuation.resume(returning: .deny)
        }
        waiters.removeAll()
    }
}

public struct AllowAllToolPolicy: Sendable {
    public init() {}

    public func authorize(_ request: ToolApprovalRequest) async -> ToolAuthResult {
        .allow
    }
}
