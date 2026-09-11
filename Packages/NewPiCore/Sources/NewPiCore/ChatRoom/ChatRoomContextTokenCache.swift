import Foundation

/// 缓存原始正文和中断标记，避免每次 UI 更新重新扫描全部历史的 Unicode 标量。
/// 每次按当前有效历史求和并裁掉失效条目，兼容检查点变更、编辑、删除和重排。
struct ChatRoomContextTokenCache {
    private struct Entry {
        let content: String
        let notice: String
        let tokens: Int
    }

    private var messages: [String: Entry] = [:]
    private var summary: Entry?

    mutating func estimatedTokens(
        room: ChatRoom,
        history: [ChatRoomMessage],
        estimate: (String) -> Int = { ContextTokenEstimator.estimate(text: $0) }
    ) -> Int {
        // 与既有估算一致：角色/阶段/触发提示 400，摘要包装 16，每条消息包装 8。
        var total = 400
        if let text = room.compactionSummary, !text.isEmpty {
            let entry: Entry
            if let cached = summary, cached.content == text {
                entry = cached
            } else {
                entry = Entry(content: text, notice: "", tokens: estimate(text))
            }
            summary = entry
            total += entry.tokens + 16
        } else {
            summary = nil
        }

        var current: [String: Entry] = [:]
        for message in ChatRoomContextBuilder.effectiveHistory(room: room, history: history)
            where message.roleID != ChatRoomContextBuilder.systemRoleID {
            let notice = message.termination?.notice ?? ""
            let entry: Entry
            if let cached = messages[message.id], cached.content == message.content, cached.notice == notice {
                entry = cached
            } else {
                entry = Entry(content: message.content, notice: notice, tokens: estimate(message.content + notice))
            }
            current[message.id] = entry
            total += entry.tokens + 8
        }
        messages = current
        return total
    }
}
