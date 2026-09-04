import Foundation

/// 聊天室工具审批管理
public actor ChatRoomApprovalManager {
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
    @Published public var pendingApprovals: [PendingApproval] = []
    
    /// 审批回调
    private var approvalContinuations: [String: CheckedContinuation<ApprovalResult, Never>] = [:]
    
    public init() {}
    
    /// 请求审批
    public func requestApproval(
        toolCall: ToolCallContent,
        roleID: String,
        roleName: String
    ) async -> ApprovalResult {
        // 读取文件自动通过
        if toolCall.name == "read_file" || toolCall.name == "list_directory" || toolCall.name == "search_files" {
            return .approved
        }
        
        // 写文件需要审批
        let description = describeToolCall(toolCall)
        let approval = PendingApproval(
            toolCall: toolCall,
            roleID: roleID,
            roleName: roleName,
            description: description
        )
        
        pendingApprovals.append(approval)
        
        // 等待审批结果
        return await withCheckedContinuation { continuation in
            approvalContinuations[approval.id] = continuation
        }
    }
    
    /// 批准
    public func approve(id: String) {
        if let continuation = approvalContinuations.removeValue(forKey: id) {
            pendingApprovals.removeAll { $0.id == id }
            continuation.resume(returning: .approved)
        }
    }
    
    /// 拒绝
    public func reject(id: String, reason: String = "用户拒绝") {
        if let continuation = approvalContinuations.removeValue(forKey: id) {
            pendingApprovals.removeAll { $0.id == id }
            continuation.resume(returning: .rejected(reason))
        }
    }
    
    /// 描述工具调用
    private func describeToolCall(_ toolCall: ToolCallContent) -> String {
        switch toolCall.name {
        case "write_file":
            if case let .object(args) = toolCall.arguments,
               case let .string(path) = args["path"] {
                return "写入文件: \(path)"
            }
            return "写入文件"
        default:
            return toolCall.name
        }
    }
}
