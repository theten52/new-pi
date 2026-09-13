import Foundation
import NewPiCore

// 仅替换运行时容器，重建算法/ID恢复直接从生产源提取；不构造真实 agent 或持久化对象。
final class SessionRuntime {
    var transcript: [NewPiTranscriptItem] = []
    var liveTranscript: [NewPiTranscriptItem]?
    var liveMessageCount = 0
    var detailLiveTurnIDByUser: [UUID: String] = [:]
    var detailMarkerIDs: [String: UUID] = [:]
}

@main struct TranscriptErrorOrderChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        print("PASS: \(message)")
    }
    static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() throws {
        let harness = RebuildHarness()
        let runtime = SessionRuntime()
        harness.activeRuntime = runtime
        let u1 = NewPiTranscriptItem(kind: .user, body: "第一轮", messageIndex: 0, sessionEntryID: "u1")
        let a1 = NewPiTranscriptItem(kind: .assistant, body: "第一轮输出", messageIndex: 1, sessionEntryID: "a1")
        let error1 = NewPiTranscriptItem(kind: .error, body: "Agent run was aborted.")
        let u2 = NewPiTranscriptItem(kind: .user, body: "第二轮", messageIndex: 2, sessionEntryID: "u2")
        let a2 = NewPiTranscriptItem(kind: .assistant, body: "第二轮输出", messageIndex: 3, sessionEntryID: "a2")
        let error2 = NewPiTranscriptItem(kind: .error, body: "第二轮网络错误")
        let messages: [AgentMessage] = [.user(u1.body), .assistant(AssistantMessage(text: a1.body, provider: "fixture", modelID: "fixture", stopReason: .aborted)),
            .user(u2.body), .assistant(AssistantMessage(text: a2.body, provider: "fixture", modelID: "fixture", stopReason: .stop))]
        runtime.transcript = [u1, a1, error1, u2, a2, error2]
        let expected = runtime.transcript.map(\.id)
        for _ in 0..<3 {
            harness.rebuildTranscript(from: messages, entryIDs: ["u1", "a1", "u2", "a2"], on: runtime)
            try require(runtime.transcript.map(\.id) == expected, "连续重建：每轮错误留在本轮末尾，ID和顺序不变")
            try require(harness.transcript.map(\.id) == expected, "活跃会话镜像与runtime一致")
        }
        // 取消时临时正文可能不在最终快照里，错误仍应跟随第一轮而非第二轮。
        let partial = NewPiTranscriptItem(kind: .assistant, body: "未提交的部分文本")
        let next = NewPiTranscriptItem(kind: .user, body: "下一轮", messageIndex: 1, sessionEntryID: "next")
        runtime.transcript = [u1, partial, error1, next]
        harness.rebuildTranscript(from: [.user(u1.body), .user(next.body)], entryIDs: ["u1", "next"], on: runtime)
        try require(runtime.transcript.map(\.id) == [u1.id, error1.id, next.id], "临时正文消失时错误仍锚定原用户轮次")
        // 新一轮尚未取得持久化 entryID 时也必须可恢复位置。
        runtime.transcript = [NewPiTranscriptItem(id: u1.id, kind: .user, body: u1.body, messageIndex: 0), error1, next]
        harness.rebuildTranscript(from: [.user(u1.body), .user(next.body)], on: runtime)
        try require(runtime.transcript.map(\.id) == [u1.id, error1.id, next.id], "未落盘entryID时按已保留的用户ID恢复轮次")
        let preflight = NewPiTranscriptItem(kind: .error, body: "尚未开始会话的配置错误")
        runtime.transcript = [preflight, u1, a1, error1]
        harness.rebuildTranscript(from: Array(messages.prefix(2)), entryIDs: ["u1", "a1"], on: runtime)
        try require(runtime.transcript.map(\.id) == [preflight.id, u1.id, a1.id, error1.id], "首轮之前的错误不挪到首轮之后")
        let summary = NewPiTranscriptItem(kind: .summary, body: "摘要")
        runtime.transcript = [u1, a1, error1, summary, u2, a2, error2]
        for _ in 0..<3 {
            harness.rebuildTranscript(from: [.compactionSummary("摘要"), .user(u2.body), messages[3]],
                entryIDs: ["summary", "u2", "a2"], on: runtime, preservedPrefixCount: 3)
            try require(runtime.transcript.filter { $0.id == error1.id }.count == 1, "压缩保留前缀中的错误不重复")
            let ids = runtime.transcript.map(\.id)
            try require(ids.firstIndex(of: error1.id)! < ids.firstIndex(of: u2.id)! && ids.last == error2.id,
                        "压缩重建后旧错误仍在旧轮次")
        }
        runtime.transcript = [u1, a1, error1, u2, a2, error2]
        harness.rebuildTranscript(from: Array(messages.prefix(2)), entryIDs: ["u1", "a1"], on: runtime)
        try require(runtime.transcript.map(\.id) == [u1.id, a1.id, error1.id], "分支截掉的轮次不把其错误带到保留轮次")
        runtime.transcript = [u1, a1]
        runtime.liveTranscript = [u1, a1, error1, u2, a2]
        harness.rebuildTranscript(from: messages, entryIDs: ["u1", "a1", "u2", "a2"], on: runtime)
        try require(runtime.transcript.map(\.id) == [u1.id, a1.id, error1.id, u2.id, a2.id], "先合并live快照再保留错误位置")
        let another = NewPiTranscriptItem(kind: .error, body: error1.body)
        runtime.transcript = [u1, a1, error1, another, u2, a2]
        harness.rebuildTranscript(from: messages, entryIDs: ["u1", "a1", "u2", "a2"], on: runtime)
        try require(runtime.transcript.map(\.id) == [u1.id, a1.id, error1.id, another.id, u2.id, a2.id],
                "同轮多个同文案错误保持各自ID和产生顺序")
        runtime.transcript = [u1, a1, u2, a2]
        harness.rebuildTranscript(from: messages, entryIDs: ["u1", "a1", "u2", "a2"], on: runtime)
        try require(runtime.transcript.map(\.id) == [u1.id, a1.id, u2.id, a2.id], "无错误会话重建顺序不变")
        #if PERSISTED_ERRORS
        // 真正经过磁盘编码/解码，再调用生产冷恢复工厂，不依赖旧内存 transcript。
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        var saved = SessionManager.rebuildContext(from: messages, header: SessionHeader(workingDirectory: directory))
        let savedError = SessionTranscriptError(id: error1.id, message: error1.body)
        saved.entries[0].transcriptErrors = [savedError]
        try JSONLSessionStore().save(saved, to: file)
        let loaded = try JSONLSessionStore().load(from: file)
        let loadedMessages = SessionManager.messages(from: loaded)
        let ids = SessionManager.messageEntries(from: loaded, leafID: loaded.leafID).map(\.0.id)
        let records = SessionManager.transcriptErrors(from: loaded, leafID: loaded.leafID)
        let cold = makeTranscriptItems(from: loadedMessages, entryIDs: ids, errors: records)
        try require(cold.map(\.body) == [u1.body, a1.body, error1.body, u2.body, a2.body], "JSONL冷恢复：错误仍显示在第一轮末尾")
        try require(cold.filter { $0.kind == .error }.map(\.id) == [error1.id], "错误ID跨磁盘恢复稳定")
        runtime.transcript = cold
        harness.rebuildTranscript(from: loadedMessages, entryIDs: ids, on: runtime)
        try require(runtime.transcript.map(\.id) == cold.map(\.id), "重启恢复后再次重建不搬移或重复错误")
        var compacted = loaded
        var leaf = compacted.leafID
        SessionManager.syncMessages([.compactionSummary("摘要"), .user("新轮次")], into: &compacted, leafID: &leaf)
        let compactedItems = makeTranscriptItems(from: SessionManager.messages(from: compacted),
            entryIDs: SessionManager.messageEntries(from: compacted, leafID: leaf).map(\.0.id),
            errors: SessionManager.transcriptErrors(from: compacted, leafID: leaf))
        try require(compactedItems.map(\.body) == [error1.body, "摘要", "新轮次"], "压缩隐藏原轮次时旧错误保留在摘要之前")
        let partialMessage = AssistantMessage(text: "已经输出的正文", reasoningContent: "中断前思考",
            provider: "test", modelID: "test", stopReason: .aborted)
        var partialSession = SessionManager.rebuildContext(from: [.user("取消轮次"), .assistant(partialMessage), .user("后续轮次")],
            header: SessionHeader(workingDirectory: directory))
        partialSession.entries[0].transcriptErrors = [savedError]
        try JSONLSessionStore().save(partialSession, to: file)
        let partialReloaded = try JSONLSessionStore().load(from: file)
        let partialItems = makeTranscriptItems(from: SessionManager.messages(from: partialReloaded),
            entryIDs: SessionManager.messageEntries(from: partialReloaded, leafID: partialReloaded.leafID).map(\.0.id),
            errors: SessionManager.transcriptErrors(from: partialReloaded, leafID: partialReloaded.leafID))
        try require(partialItems.contains { $0.kind == .thinking(isStreaming: false) && $0.body == "中断前思考" }, "重启后中断思考可展示")
        try require(partialItems.filter { $0.kind == .user || $0.kind == .assistant || $0.kind == .error }.map(\.body)
            == ["取消轮次", "已经输出的正文", error1.body, "后续轮次"], "冷恢复中断正文与错误同轮保留，不顺延到下一轮")
        #endif
        print("PASS: 真实Session转录重建错误轮次回归；无模型/用户数据")
    }
}