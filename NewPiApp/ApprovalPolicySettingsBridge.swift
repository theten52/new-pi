import Foundation
import NewPiCore

/// 危险评估策略设置桥接：管理 ApprovalPolicy 的读写与重置。
@MainActor
final class ApprovalPolicySettingsBridge: ObservableObject {
    @Published var policy: ApprovalPolicy
    /// 用户通过 UI 修改的 LLM 补充开关；改动即持久化。
    @Published var llmSupplementEnabled: Bool {
        didSet { save() }
    }
    /// 项目根内文件操作（含删除）免审批开关；改动即持久化。
    /// 对已在运行的会话不热生效，新会话/聊天室下次构建 config 时读取。
    @Published var projectScopeAutoApprove: Bool {
        didSet { save() }
    }

    private let store = ApprovalPolicyStore()

    init() {
        let loaded = store.load()
        policy = loaded
        llmSupplementEnabled = loaded.llmSupplementEnabled
        projectScopeAutoApprove = loaded.projectScopeAutoApprove
    }

    func save() {
        policy.llmSupplementEnabled = llmSupplementEnabled
        policy.projectScopeAutoApprove = projectScopeAutoApprove
        do {
            try store.save(policy)
        } catch {
            // 记录日志即可，UI 不阻塞
            NewPiLogger.error(
                category: "settings",
                message: "Failed to save approval policy",
                details: error.localizedDescription
            )
        }
    }

    func resetToDefaults() {
        policy = ApprovalPolicy()
        llmSupplementEnabled = policy.llmSupplementEnabled
        projectScopeAutoApprove = policy.projectScopeAutoApprove
        save()
    }
}
