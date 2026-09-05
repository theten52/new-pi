import Foundation

public struct CompactionConfig: Sendable, Equatable {
    public var enabled: Bool
    /// Approximate input token budget before compaction triggers.
    public var contextTokenLimit: Int
    /// Fraction of `contextTokenLimit` that triggers compaction (0–1).
    public var triggerRatio: Double
    /// Recent messages kept verbatim after compaction.
    public var keepRecentMessages: Int

    public init(
        enabled: Bool = true,
        contextTokenLimit: Int = 96_000,
        triggerRatio: Double = 0.75,
        keepRecentMessages: Int = 8
    ) {
        self.enabled = enabled
        self.contextTokenLimit = contextTokenLimit
        self.triggerRatio = triggerRatio
        self.keepRecentMessages = keepRecentMessages
    }

    public var triggerTokenCount: Int {
        max(1, Int(Double(contextTokenLimit) * triggerRatio))
    }

    /// 已知模型上下文窗口时的推荐预算：窗口 × 0.8（留 20% 给本轮输出与压缩摘要）。
    /// 固定 96k 预算与模型窗口脱钩：大窗口模型被过早压缩丢上下文，
    /// 小窗口模型压缩太晚直接超窗（2026-09-05 限制调研结论）。
    public static func recommended(contextWindow: Int) -> CompactionConfig {
        CompactionConfig(
            enabled: true,
            contextTokenLimit: max(1, Int(Double(contextWindow) * 0.8)),
            triggerRatio: 0.75,
            keepRecentMessages: 8
        )
    }
}
