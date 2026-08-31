import Foundation

/// 模型上下文窗口大小目录表（modelID → context window token 数）。
///
/// 上下文窗口是模型出厂即固定的物理容量，不应让用户手填，也不可从请求推断
/// （请求只回传 usage，不回传窗口上限）。业界通用做法（Claude Code / Aider /
/// Continue 等）是维护一份静态目录表 + provider 兜底。
///
/// 这里的数值为内置默认值，按模型官方标称填写，若有出入可直接调整本表。
public enum ContextWindowCatalog {
    /// 各模型上下文窗口 token 数（值均为官方标称，按需维护）。
    private static let windows: [String: Int] = [
        // Anthropic（Claude 系列均为 200k）。
        "claude-sonnet-4-5": 200_000,
        "claude-opus-4-1": 200_000,
        "claude-sonnet-4-20250514": 200_000,
        "claude-opus-4-20250514": 200_000,
        "claude-3-5-haiku-20241022": 200_000,

        // OpenAI。
        "gpt-5": 400_000,
        "gpt-5-mini": 400_000,
        "gpt-4o": 128_000,
        "gpt-4o-mini": 200_000,
        "gpt-4.1-mini": 1_000_000,

        // DeepSeek。
        "deepseek-v4-flash": 1_000_000,
        "deepseek-v4-pro": 1_000_000,
        "deepseek-v4-flash-vision-exp": 1_000_000,
        "deepseek-chat": 128_000,
        "deepseek-reasoner": 128_000,
    ]

    /// provider 级兜底：目录表中查不到的模型按 preset 走此默认值。
    private static func fallback(for preset: ProviderPreset) -> Int {
        switch preset {
        case .anthropic: 200_000
        case .openai: 128_000
        case .openaiCompatible: 128_000
        case .openRouter: 128_000
        case .ollama: 128_000
        case .xiaomiMiMo: 128_000
        }
    }

    /// 查询某模型的上下文窗口 token 数。
    ///
    /// 精确匹配优先；其次按子串匹配（兼容 OpenRouter 的 `anthropic/claude-…`、
    /// `openai/gpt-…` 这类带前缀的 modelID）；仍查不到则回落到 provider 兜底。
    public static func windowTokens(for modelID: String, preset: ProviderPreset) -> Int {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = windows[trimmed] {
            return exact
        }
        for (key, value) in windows where trimmed.contains(key) {
            return value
        }
        return fallback(for: preset)
    }

    /// 是否为「未收录、走了兜底」的模型（供 UI 提示或测试断言使用）。
    public static func isKnown(_ modelID: String) -> Bool {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if windows[trimmed] != nil {
            return true
        }
        return windows.keys.contains { trimmed.contains($0) }
    }
}
