import Foundation
import NewPiCore

@main
struct ChatRoomRenderingChecks {
    static func main() {
        let roomID = UUID().uuidString, speechID = UUID().uuidString
        let role = ChatRoomRole(name: "角色 A", description: "", systemPrompt: "")
        var message = ChatRoomMessage(chatroomID: roomID, roleID: role.id, content: "", reasoningContent: "thinking",
            speechID: speechID, phase: .discussion)
        let user = ChatRoomMessage(chatroomID: roomID, roleID: "user", content: "插话", phase: .discussion)
        var adapter = ChatRoomTranscriptAdapter()
        var live = ChatRoomLiveSpeech(id: speechID, messageID: message.id, phase: .thinking)
        let before = adapter.adapt(messages: [message], roles: [role], liveSpeech: live).items
        let interrupted = adapter.adapt(messages: [message, user], roles: [role], liveSpeech: live).items
        precondition(interrupted.contains { $0.kind == .thinking(isStreaming: true) })
        precondition(interrupted.contains { $0.kind == .detailGroup(collapsed: false) })
        precondition(before.first { $0.kind == .thinking(isStreaming: true) }?.id == interrupted.first { $0.kind == .thinking(isStreaming: true) }?.id)

        message.content = "正文仍在输出"
        live.phase = .text
        let writing = adapter.adapt(messages: [message, user], roles: [role], liveSpeech: live).items
        let answer = writing.first { $0.kind == .assistant }!
        precondition(writing.last?.kind == .user)
        precondition(answer.isStreaming(isRunning: true, bubbleComplete: false, lastItemID: writing.last?.id))
        precondition(writing.contains { $0.kind == .thinking(isStreaming: false) })
        precondition(answer.speaker == role.name && !answer.canFork)

        live.phase = .complete
        let finished = adapter.adapt(messages: [message], roles: [role], liveSpeech: live).items
        precondition(!finished.last!.isStreaming(isRunning: true, bubbleComplete: false, lastItemID: finished.last?.id))
        let idle = adapter.adapt(messages: [message, user], roles: [role], liveSpeech: nil).items
        precondition(idle.contains { $0.kind == .detailGroup(collapsed: true) })
        precondition(!idle.contains { $0.isStreamingThinking })

        // 新分段开始时，仅新段流式；工具记录和历史正文都保持静态。
        message.toolCalls = [ChatRoomToolCall(id: "tool", name: "read", arguments: "{}")]
        message.toolResults = [ChatRoomToolResult(toolCallID: "tool", output: "done")]
        let next = ChatRoomMessage(chatroomID: roomID, roleID: role.id, content: "final", speechID: speechID, phase: .discussion)
        live = ChatRoomLiveSpeech(id: speechID, messageID: next.id, phase: .text)
        let segments = adapter.adapt(messages: [message, next, user], roles: [role], liveSpeech: live).items
        let streaming = segments.filter { $0.isStreaming(isRunning: true, bubbleComplete: false, lastItemID: segments.last?.id) }
        precondition(streaming.map(\.id) == [UUID(uuidString: next.id)!])
        precondition(segments.first { $0.id == UUID(uuidString: message.id)! }?.detailTurnID == speechID)

        message.termination = .cancelled
        let cancelled = adapter.adapt(messages: [message, user], roles: [role], liveSpeech: nil).items
        precondition(cancelled.contains { $0.kind == .detailGroup(collapsed: false) })
        precondition(cancelled.contains { $0.kind == .system && $0.body.contains("停止不代表") })

        // Session 未使用显式 override，末条 assistant 和 bubbleComplete 语义保持原样。
        let session = NewPiTranscriptItem(kind: .assistant, body: "session")
        precondition(session.isStreaming(isRunning: true, bubbleComplete: false, lastItemID: session.id))
        precondition(!session.isStreaming(isRunning: true, bubbleComplete: true, lastItemID: session.id))
        precondition(!session.isStreaming(isRunning: true, bubbleComplete: false, lastItemID: user.idAsUUID))
        print("PASS: actual adapter + shared streaming predicate: steering, thinking, message end, multi-segment IDs, cancellation, Session compatibility")
    }
}

private extension ChatRoomMessage {
    var idAsUUID: UUID? { UUID(uuidString: id) }
}
