import Foundation

/// 每个聊天室独立持有；跨角色/发言记忆，但不继承 Session 或全局永久授权。
@MainActor
public final class ChatRoomApprovalManager: ObservableObject {
    public let tracker = ToolApprovalTracker(persistentStore: nil)
    public let policyStore: ApprovalPolicyStore

    public struct PendingApproval: Identifiable, Sendable {
        public let id: String
        public let toolCall: ToolCallContent
        public let roleID: String
        public let roleName: String
        public let description: String
        public let dangerLevel: ToolDangerLevel
        public let dangerReason: String?
        public let parametersFingerprint: String

        public init(id: String = UUID().uuidString, toolCall: ToolCallContent,
                    roleID: String, roleName: String, description: String,
                    dangerLevel: ToolDangerLevel = .medium, dangerReason: String? = nil,
                    parametersFingerprint: String? = nil) {
            self.id = id
            self.toolCall = toolCall
            self.roleID = roleID
            self.roleName = roleName
            self.description = description
            self.dangerLevel = dangerLevel
            self.dangerReason = dangerReason
            self.parametersFingerprint = parametersFingerprint ?? ToolApprovalFingerprint.make(arguments: toolCall.arguments)
        }

        public var request: ToolApprovalRequest {
            ToolApprovalRequest(id: id, toolName: toolCall.name, arguments: toolCall.arguments,
                summary: description, dangerLevel: dangerLevel, dangerReason: dangerReason,
                parametersFingerprint: parametersFingerprint)
        }
    }

    public enum ApprovalResult: Sendable {
        case approved
        case rejected(String)
    }

    @Published public private(set) var pendingApprovals: [PendingApproval] = []
    @Published public private(set) var hasRememberedApprovals = false
    private typealias Response = (decision: ApprovalDecision, reason: String?)
    private var continuations: [String: CheckedContinuation<Response, Never>] = [:]

    public nonisolated init(policyStore: ApprovalPolicyStore = ApprovalPolicyStore()) {
        self.policyStore = policyStore
    }

    /// 由控制器在空闲时调用；重启 App/销毁控制器也自然清除内存授权。
    public func clearRememberedApprovals() async {
        await tracker.reset()
        hasRememberedApprovals = false
    }

    /// 兼容 provider 路径统一到相同的风险评估和授权记忆，不再固定只允许一次。
    public func requestApproval(toolCall: ToolCallContent, roleID: String, roleName: String) async -> ApprovalResult {
        guard !Task.isCancelled else { return .rejected("已取消") }
        if ["read_file", "list_directory", "search_files"].contains(toolCall.name) { return .approved }
        // 旧工具名映射到执行引擎的 canonical name，避免 write_file/write 授权不一致。
        let name = toolCall.name == "write_file" ? "write" : toolCall.name
        let assessment = await DangerEvaluator(policy: policyStore.load()).evaluate(
            toolName: name, arguments: toolCall.arguments, cache: nil)
        if assessment.level == .low { return Task.isCancelled ? .rejected("已取消") : .approved }
        let request = ToolApprovalRequest(id: toolCall.id, toolName: name, arguments: toolCall.arguments,
            summary: ToolApprovalSummary.make(toolName: name, arguments: toolCall.arguments),
            dangerLevel: assessment.level, dangerReason: assessment.reason)
        let response = await requestDecision(for: request, roleID: roleID, roleName: roleName)
        return response.decision.approved ? .approved : .rejected(response.reason ?? "用户拒绝")
    }

    public func approvalDecision(for request: ToolApprovalRequest, roleID: String, roleName: String) async -> ApprovalDecision {
        await requestDecision(for: request, roleID: roleID, roleName: roleName).decision
    }

    private func requestDecision(for request: ToolApprovalRequest, roleID: String, roleName: String) async -> Response {
        guard !Task.isCancelled else { return (.deny, "已取消") }
        if await tracker.isAuthorized(toolName: request.toolName, fingerprint: request.parametersFingerprint,
                                      dangerLevel: request.dangerLevel) {
            return Task.isCancelled ? (.deny, "已取消") : (.allowOnce, nil)
        }
        guard !Task.isCancelled else { return (.deny, "已取消") }
        let approval = PendingApproval(toolCall: ToolCallContent(id: request.id, name: request.toolName, arguments: request.arguments),
            roleID: roleID, roleName: roleName, description: request.summary,
            dangerLevel: request.dangerLevel, dangerReason: request.dangerReason,
            parametersFingerprint: request.parametersFingerprint)
        let result: Response = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Response, Never>) in
                guard !Task.isCancelled else { continuation.resume(returning: (ApprovalDecision.deny, "已取消")); return }
                // 先注册再发布 UI，保证同步响应和取消均能找到 continuation。
                continuations[approval.id] = continuation
                pendingApprovals.append(approval)
            }
        } onCancel: {
            Task { @MainActor in self.resume(id: approval.id, decision: .deny, reason: "已取消") }
        }
        guard !Task.isCancelled else { return (.deny, "已取消") }
        if result.decision.approved, result.decision.scope == .session {
            await tracker.record(scope: .session, toolName: request.toolName,
                fingerprint: request.parametersFingerprint, dangerLevel: request.dangerLevel)
            hasRememberedApprovals = true
        }
        return result
    }

    public func approve(id: String, scope: ApprovalScope = .once) {
        guard let approval = pendingApprovals.first(where: { $0.id == id }) else { return }
        // UI 之外也强制约束：聊天室不支持 forever，高危只能允许一次。
        let effectiveScope: ApprovalScope = scope == .session && approval.dangerLevel != .high ? .session : .once
        let decision = ApprovalDecision(approved: true, scope: effectiveScope)
        if effectiveScope == .session {
            // 同工具已有排队审批也属于本次明确授权；不同工具/高危请求仍需单独确认。
            let covered = pendingApprovals.filter { $0.toolCall.name == approval.toolCall.name && $0.dangerLevel != .high }.map(\.id)
            for pendingID in covered { resume(id: pendingID, decision: decision) }
        } else {
            resume(id: id, decision: decision)
        }
    }

    public func reject(id: String, reason: String = "用户拒绝") {
        resume(id: id, decision: .deny, reason: reason)
    }

    private func resume(id: String, decision: ApprovalDecision, reason: String? = nil) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pendingApprovals.removeAll { $0.id == id }
        continuation.resume(returning: (decision, reason))
    }
}
