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
}
