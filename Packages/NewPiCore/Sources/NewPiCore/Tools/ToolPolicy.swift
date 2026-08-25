import Foundation

public struct ToolApprovalRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var toolName: String
    public var arguments: JSONValue
    public var summary: String

    public init(id: String, toolName: String, arguments: JSONValue, summary: String) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.summary = summary
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
            let path = arguments.objectValue?["path"]?.stringValue ?? "?"
            return "Read file: \(path)"
        case "write":
            let path = arguments.objectValue?["path"]?.stringValue ?? "?"
            let content = arguments.objectValue?["content"]?.stringValue ?? ""
            let preview = String(content.prefix(120))
            return "Write file: \(path)\n\(preview)\(content.count > 120 ? "…" : "")"
        case "edit":
            let path = arguments.objectValue?["path"]?.stringValue ?? "?"
            let oldText = arguments.objectValue?["old_string"]?.stringValue ?? ""
            let newText = arguments.objectValue?["new_string"]?.stringValue ?? ""
            return """
            Edit file: \(path)
            - \(oldText.prefix(80))\(oldText.count > 80 ? "…" : "")
            + \(newText.prefix(80))\(newText.count > 80 ? "…" : "")
            """
        case "bash":
            let command = arguments.objectValue?["command"]?.stringValue ?? "?"
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

/// Tracks tools that have been approved for the lifetime of a session,
/// so repeated calls to the same tool do not require re-approval.
public actor ToolApprovalTracker {
    private var approvedToolNames: Set<String> = []

    public init() {}

    public func markApproved(_ toolName: String) {
        NewPiLogger.info(
            category: "tool-approval",
            message: "Tool marked approved for session",
            details: "tool=\(toolName)"
        )
        approvedToolNames.insert(toolName)
    }

    public func isApproved(_ toolName: String) -> Bool {
        approvedToolNames.contains(toolName)
    }

    public func reset() {
        approvedToolNames.removeAll()
    }
}

/// Waits for UI or test harness to approve/deny a tool call.
public actor ToolApprovalGate {
    private struct PendingRequest {
        let toolName: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waiters: [String: PendingRequest] = [:]

    public init() {}

    public func wait(for request: ToolApprovalRequest) async -> Bool {
        NewPiLogger.debug(
            category: "tool-approval",
            message: "Approval gate waiting",
            details: "requestID=\(request.id) tool=\(request.toolName)"
        )
        return await withCheckedContinuation { continuation in
            waiters[request.id] = PendingRequest(
                toolName: request.toolName,
                continuation: continuation
            )
        }
    }

    @discardableResult
    public func respond(requestID: String, approved: Bool) -> String? {
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
            details: "requestID=\(requestID) approved=\(approved) tool=\(pending.toolName) pendingWaiters=\(waiters.keys.sorted())"
        )
        pending.continuation.resume(returning: approved)
        return pending.toolName
    }

    public func cancelAll() {
        NewPiLogger.info(
            category: "tool-approval",
            message: "Approval gate cancelled all pending requests",
            details: "count=\(waiters.count)"
        )
        for (_, pending) in waiters {
            pending.continuation.resume(returning: false)
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
