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

/// Waits for UI or test harness to approve/deny a tool call.
public actor ToolApprovalGate {
    private var waiters: [String: CheckedContinuation<Bool, Never>] = [:]

    public init() {}

    public func wait(for requestID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            waiters[requestID] = continuation
        }
    }

    public func respond(requestID: String, approved: Bool) {
        guard let continuation = waiters.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: approved)
    }

    public func cancelAll() {
        for (_, continuation) in waiters {
            continuation.resume(returning: false)
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
