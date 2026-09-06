import Foundation
import NewPiCore

/// 聊天室消息 → transcript items 适配层（CHATROOM-FLAT-MD Phase 2）。
///
/// 把 ChatRoomRuntime.messages 映射为单文档管线可渲染的 `[NewPiTranscriptItem]`，
/// 复用 session 的 markdown / 工具卡 / 滚动管线。聊天室无流式、无 fork、无详情折叠组：
/// `messageIndex` / `detailTurnID` 一律 nil（canFork 为 false，JS 不渲染 Fork 按钮）。
///
/// 映射规则（方案 §三.E）：
/// - 用户消息 → .user；角色发言 → .assistant（speaker = 角色名，tint 按角色着色）；
/// - phase 切换处插 .system 分隔行；候选方案拼进 markdown body；toolCalls → 工具卡。
struct ChatRoomTranscriptAdapter {
    /// 派生条目的稳定 id 缓存：phase 分隔行 / 工具卡无原生 UUID，按 key 懒建并缓存，
    /// 保证跨 diff id 稳定（不漂移 → 不触发 DOM 重建）。挂在 FlowController 生命周期上。
    private var derivedIDs: [String: UUID] = [:]

    /// 角色 tint 色相：FNV-1a 哈希（需求方确认，跨启动稳定；不用 hashValue——它每次启动随机）。
    static func hue(for roleID: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in roleID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return Int(hash % 360)
    }

    /// 阶段名（文案与原 PhaseHeader 一致）。
    static func phaseName(_ phase: ChatRoomPhase) -> String {
        switch phase {
        case .discussion: "讨论"
        case .voting: "投票"
        case .execution: "执行"
        case .review: "Review"
        case .completed: "完成"
        }
    }

    /// 全量重算（聊天室消息量级小，O(n) 可接受）；调用方按 controller 生命周期持有本实例。
    /// isRunning：实时发言期间，最后一条消息的思考条目保持流式（✦ 光标），
    /// 正文开始后冻结——与 session 的 thinking 语义一致。
    mutating func adapt(
        messages: [ChatRoomMessage],
        roles: [ChatRoomRole],
        isRunning: Bool
    ) -> (items: [NewPiTranscriptItem], tintHues: [UUID: Int]) {
        var items: [NewPiTranscriptItem] = []
        var tintHues: [UUID: Int] = [:]
        var lastPhase: ChatRoomPhase?
        let lastMessageID = messages.last?.id

        for message in messages {
            // phase 切换处插分隔行（原 PhaseHeader 的文档内化，方案决策 4）：
            // id 以组内首条消息派生，插叙不漂移。
            if message.phase != lastPhase {
                items.append(NewPiTranscriptItem(
                    id: derivedID("phase-\(message.id)"),
                    kind: .system,
                    body: "—— \(Self.phaseName(message.phase)) 阶段 ——"
                ))
                lastPhase = message.phase
            }
            guard let messageID = UUID(uuidString: message.id) else { continue }

            // 系统标记（自动压缩等，roleID=system）：仅展示行，不渲染成角色发言
            if message.roleID == ChatRoomContextBuilder.systemRoleID {
                items.append(NewPiTranscriptItem(id: messageID, kind: .system, body: message.content))
                continue
            }

            // 思考过程：正文前补 thinking 条目（与 session 的 reasoningContent 渲染一致）；
            // 实时发言中且正文未开始 → 流式（✦ 光标），正文开始后冻结
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                items.append(NewPiTranscriptItem(
                    id: derivedID("thinking-\(message.id)"),
                    kind: .thinking(isStreaming: isRunning && message.id == lastMessageID && message.content.isEmpty),
                    body: reasoning
                ))
            }

            if message.isUserMessage {
                items.append(NewPiTranscriptItem(id: messageID, kind: .user, body: message.content))
                continue
            }

            // 角色发言：正文 + 候选方案（决策 5：v1 拼进 markdown，不新增 kind）。
            var body = message.content
            if let candidates = message.candidates, !candidates.isEmpty {
                let list = candidates.map { "- **\($0.title)**：\($0.description)" }.joined(separator: "\n")
                body += "\n\n**候选方案**\n\n\(list)"
            }
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let roleName = roles.first(where: { $0.id == message.roleID })?.name ?? "未知角色"
                items.append(NewPiTranscriptItem(
                    id: messageID,
                    kind: .assistant,
                    body: body,
                    speaker: roleName
                ))
                tintHues[messageID] = Self.hue(for: message.roleID)
            }

            // 工具调用 → 处理详情组（Phase A）：同一发言的工具卡收进一个可折叠组，
            // 实时发言中保持展开（卡片随执行出现），发言完成自动收起为一行；
            // 彻底解决长工具循环（如 500 轮）把 transcript 刷屏的问题。
            let chatroomToolCalls = message.toolCalls ?? []
            if !chatroomToolCalls.isEmpty {
                let groupTurnID = "speak-\(message.id)"
                // marker 自身必须携带 detailTurnID（组的身份行，对齐 session 的
                // detailGroup 条目语义），否则 JS 无法把工具卡归组
                items.append(NewPiTranscriptItem(
                    id: derivedID("detail-\(message.id)"),
                    kind: .detailGroup(collapsed: !(isRunning && message.id == lastMessageID)),
                    body: "",
                    detailTurnID: groupTurnID
                ))
                for call in chatroomToolCalls {
                    let result = message.toolResults?.first(where: { $0.toolCallID == call.id })
                    items.append(NewPiTranscriptItem(
                        id: derivedID("tool-\(call.id)"),
                        kind: .tool(
                            name: call.name,
                            state: result.map { .completed(isError: $0.isError) } ?? .running
                        ),
                        body: result?.output ?? "",
                        toolCommand: Self.truncate(call.arguments),
                        detailTurnID: groupTurnID
                    ))
                }
            }
        }
        return (items, tintHues)
    }

    private mutating func derivedID(_ key: String) -> UUID {
        if let id = derivedIDs[key] { return id }
        let id = UUID()
        derivedIDs[key] = id
        return id
    }

    /// 工具参数摘要：压缩成单行并截断（对齐 newPiToolCommandSummary 的防超长思路）。
    private static func truncate(_ text: String, maxLength: Int = 200) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength)) + "…"
    }
}
