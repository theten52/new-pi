import Foundation

public enum ContextTokenEstimator {
    /// Rough token estimate for compaction heuristics.
    public static func estimate(messages: [AgentMessage], systemPrompt: String) -> Int {
        let systemTokens = estimateText(systemPrompt)
        let messageTokens = messages.reduce(into: 0) { total, message in
            total += estimate(message)
        }
        return systemTokens + messageTokens
    }

    /// 单段文本的 token 估算（聊天室预算提示等外部场景复用）
    public static func estimate(text: String) -> Int {
        estimateText(text)
    }

    public static func estimate(_ message: AgentMessage) -> Int {
        switch message {
        case let .user(user):
            estimateText(user.content) + 4
        case let .assistant(assistant):
            estimateText(assistant.text)
                + assistant.toolCalls.reduce(into: 0) { total, call in
                    total += estimateText(call.name)
                    total += estimateText(String(describing: call.arguments))
                }
                + 8
        case let .toolResult(result):
            estimateText(result.content) + estimateText(result.toolName) + 6
        case let .compactionSummary(summary):
            estimateText(summary) + 4
        }
    }

    /// 按字符集加权估算：
    /// - CJK（汉字/假名/谚文/全角）≈ 1 字符 1 token
    /// - 可打印 ASCII ≈ 4 字符 1 token
    /// - 其余（带变音符拉丁文、西里尔、emoji 等）取中间值 ≈ 2 字符 1 token
    ///
    /// 之前统一按 4 字符/token 估算，中文内容被低估 3~4 倍，导致压缩触发
    /// 过晚、真实上下文超出模型窗口（2026-09-05 限制调研结论）。
    private static func estimateText(_ text: String) -> Int {
        var ascii = 0
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x20...0x7E:
                ascii += 1
            case 0x3000...0x303F,   // CJK 符号与标点
                 0x3040...0x30FF,   // 平假名、片假名
                 0x3400...0x4DBF,   // CJK 扩展 A
                 0x4E00...0x9FFF,   // CJK 统一表意文字
                 0xAC00...0xD7AF,   // 谚文音节
                 0xF900...0xFAFF,   // CJK 兼容表意文字
                 0xFF00...0xFFEF:   // 全角与半角形式
                cjk += 1
            default:
                other += 1
            }
        }
        return max(1, ascii / 4 + cjk + other / 2)
    }
}
