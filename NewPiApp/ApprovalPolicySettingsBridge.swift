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

    private let store = ApprovalPolicyStore()

    init() {
        let loaded = store.load()
        policy = loaded
        llmSupplementEnabled = loaded.llmSupplementEnabled
    }

    func save() {
        policy.llmSupplementEnabled = llmSupplementEnabled
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
        save()
    }
}
