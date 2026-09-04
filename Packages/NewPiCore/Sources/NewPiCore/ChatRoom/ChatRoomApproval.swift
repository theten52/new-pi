import Foundation

/// 聊天室工具审批管理
///
/// @MainActor ObservableObject：UI 直接观察 `pendingApprovals` 弹出审批卡片；
/// actor 内的 `@Published` 无法驱动 SwiftUI 刷新，因此不用 actor。
/// 审批等待对 Task 取消敏感：停止运行时未决审批以「已取消」拒绝并唤醒循环。
@MainActor
public final class ChatRoomApprovalManager: ObservableObject {
    /// 待审批的工具调用
    public struct PendingApproval: Identifiable, Sendable {
        public let id: String
        public let toolCall: ToolCallContent
        public let roleID: String
        public let roleName: String
        public let description: String

        public init(
            id: String = UUID().uuidString,
            toolCall: ToolCallContent,
            roleID: String,
            roleName: String,
            description: String
        ) {
            self.id = id
            self.toolCall = toolCall
            self.roleID = roleID
            self.roleName = roleName
            self.description = description
        }
    }

    /// 审批结果
    public enum ApprovalResult: Sendable {
        case approved
        case rejected(String)
    }

    /// 待审批列表
    @Published public private(set) var pendingApprovals: [PendingApproval] = []

    private var continuations: [String: CheckedContinuation<ApprovalResult, Never>] = [:]

    /// nonisolated：允许在非隔离上下文（如工厂默认参数）中构造空实例
    public nonisolated init() {}

    /// 请求审批。读文件、列目录、搜索自动通过；写文件挂起等待用户决定。
    public func requestApproval(
        toolCall: ToolCallContent,
        roleID: String,
        roleName: String
    ) async -> ApprovalResult {
        // 简化审批（决策 #18）：读类工具自动通过
        if toolCall.name == "read_file" || toolCall.name == "list_directory" || toolCall.name == "search_files" {
            return .approved
        }

        let approval = PendingApproval(
            toolCall: toolCall,
            roleID: roleID,
            roleName: roleName,
            description: describeToolCall(toolCall)
        )
        pendingApprovals.append(approval)

        let approvalID = approval.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // 取消可能先于本闭包执行（onCancel 在已取消任务上立即触发），
                // 注册前再查一次，保证 continuation 不会无人唤醒。
                if Task.isCancelled {
                    continuation.resume(returning: .rejected("已取消"))
                    return
                }
                self.continuations[approvalID] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelPending(approvalID: approvalID)
            }
        }
    }

    /// 批准
    public func approve(id: String) {
        resume(id: id, result: .approved)
    }

    /// 拒绝
    public func reject(id: String, reason: String = "用户拒绝") {
        resume(id: id, result: .rejected(reason))
    }

    private func resume(id: String, result: ApprovalResult) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pendingApprovals.removeAll { $0.id == id }
        continuation.resume(returning: result)
    }

    private func cancelPending(approvalID: String) {
        guard continuations[approvalID] != nil else { return }
        resume(id: approvalID, result: .rejected("已取消"))
    }

    /// 描述工具调用（审批卡片展示用）
    private func describeToolCall(_ toolCall: ToolCallContent) -> String {
        switch toolCall.name {
        case "write_file":
            var text = "写入文件"
            if case let .object(args) = toolCall.arguments {
                if case let .string(path) = args["path"] {
                    text = "写入文件: \(path)"
                }
                if case let .string(content) = args["content"] {
                    let preview = content.count > 300 ? String(content.prefix(300)) + "…" : content
                    text += "\n\n内容预览:\n\(preview)"
                }
            }
            return text
        default:
            return toolCall.name
        }
    }
}
