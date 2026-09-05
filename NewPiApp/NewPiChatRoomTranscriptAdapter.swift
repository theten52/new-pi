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
    mutating func adapt(
        messages: [ChatRoomMessage],
        roles: [ChatRoomRole]
    ) -> (items: [NewPiTranscriptItem], tintHues: [UUID: Int]) {
        var items: [NewPiTranscriptItem] = []
        var tintHues: [UUID: Int] = [:]
        var lastPhase: ChatRoomPhase?

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

            // 工具调用 → 工具卡（现成 renderCard；arguments 摘要截断防超长）。
            for call in message.toolCalls ?? [] {
                let result = message.toolResults?.first(where: { $0.toolCallID == call.id })
                items.append(NewPiTranscriptItem(
                    id: derivedID("tool-\(call.id)"),
                    kind: .tool(name: call.name, state: .completed(isError: result?.isError ?? false)),
                    body: result?.output ?? "",
                    toolCommand: Self.truncate(call.arguments)
                ))
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
