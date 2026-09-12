import Foundation
import NewPiCore

/// 仅替换窗口/厂商配置读取；会话、重试、事件处理、流式缓冲和重建均为生产代码。
@main @MainActor struct SessionRetryVMChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        print("PASS: \(message)")
    }
    final class Provider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
            -> AsyncThrowingStream<LLMStreamEvent, Error> {
            let call = lock.withLock { calls += 1; return calls }
            return AsyncThrowingStream { continuation in
                continuation.yield(.thinkingDelta("思考"))
                continuation.yield(.textDelta(call == 1 ? "部分正文" : "恢复回答"))
                if call == 1 { continuation.finish(throwing: URLError(.cannotConnectToHost)) }
                else {
                    continuation.yield(.completed(stopReason: .stop, usage: UsageStats()))
                    continuation.finish()
                }
            }
        }
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let provider = Provider()
        let model = ModelConfig(provider: "fixture-provider", modelID: "fixture-model")
        let session = AgentSession(context: AgentContext(systemPrompt: "fixture", workingDirectory: dir),
            config: AgentLoopConfig(model: model, llm: provider))
        await session.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        let runtime = SessionRuntime(session: session, fileURL: file, sessionID: UUID())
        let harness = VMHarness()
        harness.activeRuntime = runtime
        var iterator = await session.events().makeAsyncIterator()
        let user = UserMessage(content: "问题", timestamp: Date(timeIntervalSince1970: 1234))
        runtime.transcript = [NewPiTranscriptItem(kind: .user, body: user.content, messageIndex: 0, timestamp: user.timestamp)]
        runtime.isStreaming = true
        await session.prompt(.user(user))
        while let event = await iterator.next() {
            await harness.handle(event, on: runtime)
            if case .error = event {
                try require(runtime.isStreaming && runtime.turnOutcome == "失败", "error到agentEnd间仍锁定发送且标记失败")
            }
            if case .agentEnd = event { break }
        }
        let error = try unwrap(runtime.transcript.last(where: { $0.kind == .error }))
        try require(error.retryState == "available" && error.errorTitle == "连接失败", "真实连接失败卡可重试")
        try require(error.timestamp != nil && error.provider == model.provider && error.modelID == model.modelID, "错误真实时间与请求模型元数据")
        try require(runtime.turnStatusText == "失败" && runtime.turnSummaryText == nil, "agentEnd保留failed主状态，无工具时summary为空")
        try require(runtime.transcript.first?.timestamp == user.timestamp, "User timestamp经过重建不变")
        let assistant = try unwrap(runtime.transcript.first(where: { $0.kind == .assistant }))
        try require(assistant.body == "部分正文" && assistant.timestamp != nil && assistant.provider == model.provider, "partial重建保正文与真实元数据")
        harness.activeRuntime = nil
        harness.retryError(id: error.id, on: runtime)
        try require(!runtime.isStreaming && provider.count == 1, "非当前runtime不能重试")
        harness.activeRuntime = runtime
        harness.retryError(id: error.id, on: runtime)
        harness.retryError(id: error.id, on: runtime)
        try require(runtime.isStreaming && runtime.turnStatusText == "正在重试", "同步领取双击锁并展示retrying")
        try require(runtime.transcript.last(where: { $0.id == error.id })?.retryState == "retrying", "原错误卡立即变为retrying")
        while let event = await iterator.next() {
            await harness.handle(event, on: runtime)
            if case .agentEnd = event { break }
        }
        try require(provider.count == 2, "双击只触发一次真实provider重试")
        try require(runtime.transcript.filter { $0.kind == .user }.count == 1, "重试不重复user")
        try require(runtime.transcript.filter { $0.kind == .assistant }.map(\.body) == ["部分正文", "恢复回答"], "live/rebuild保留partial且不拼接成同一回答")
        try require(runtime.transcript.last(where: { $0.id == error.id })?.retryState == "recovered", "原卡持久状态为recovered")
        try require(runtime.turnStatusText == "已恢复" && runtime.turnSummaryText == nil, "重试完成保留recovered主状态，无工具时summary为空")
        let stored = try JSONLSessionStore().load(from: file)
        let messages = SessionManager.messages(from: stored)
        let entries = SessionManager.messageEntries(from: stored, leafID: stored.leafID).map(\.0.id)
        let errors = SessionManager.transcriptErrors(from: stored, leafID: stored.leafID)
        try require(restoredTurnOutcome(messages: messages, errors: errors, entryIDs: entries) == "已恢复", "首次冷恢复识别recovered")
        let cold = makeTranscriptItems(from: messages, entryIDs: entries, errors: errors)
        try require(cold.last(where: { $0.id == error.id })?.retryState == "recovered", "冷恢复错误卡保原ID和状态")
        let metadata = NewPiTranscriptItem(kind: .thinking(isStreaming: true), body: "x", attachments: [], speaker: "角色",
            streamingOverride: true, timestamp: user.timestamp, provider: "p", modelID: "m", errorTitle: "标题", retryState: "available")
        var live = [metadata]
        harness.freezeStreamingThinking(into: &live)
        try require(live[0].timestamp == metadata.timestamp && live[0].provider == "p" && live[0].modelID == "m"
            && live[0].speaker == "角色" && live[0].streamingOverride == true && live[0].errorTitle == "标题" && live[0].retryState == "available", "冻结复制保留所有可选元数据")
        runtime.transcript += [NewPiTranscriptItem(kind: .tool(name: "a", state: .completed(isError: false)), body: ""),
            NewPiTranscriptItem(kind: .tool(name: "b", state: .completed(isError: true)), body: ""),
            NewPiTranscriptItem(kind: .tool(name: "c", state: .running), body: "")]
        let counts = "工具：已完成 1 · 失败 1 · 运行中 1"
        try require(runtime.turnSummaryText == counts, "summary只统计真实完成/失败/运行中工具")
        let summaryRuntime = SessionRuntime(session: session, fileURL: file, sessionID: UUID())
        summaryRuntime.transcript = [NewPiTranscriptItem(kind: .user, body: "问题"),
            NewPiTranscriptItem(kind: .assistant, body: "回答")]
        summaryRuntime.turnOutcome = "已完成"
        try require(summaryRuntime.turnStatusText == "已完成" && summaryRuntime.turnSummaryText == nil, "纯文本已完成只有主状态，无额外summary")
        summaryRuntime.transcript = runtime.transcript
        for outcome in ["已完成", "失败", "已恢复", "已停止", "已停止（未完成）"] {
            summaryRuntime.turnOutcome = outcome
            try require(summaryRuntime.turnStatusText == outcome && summaryRuntime.turnSummaryText == counts,
                "结束态\(outcome)保留主状态，summary不重复结果")
        }
        // 无新锚点的校验错误不能复用旧卡，agentEnd不能用旧成功覆盖失败。
        await harness.handle(.error(.invalidState("fixture validation")), on: runtime)
        await harness.handle(.agentEnd, on: runtime)
        try require(runtime.turnOutcome == "失败" && runtime.transcript.contains { $0.kind == .error && $0.retryState == "unavailable" }, "无已接受user的校验错误不可重试且不被旧成功覆盖")
        await session.shutdown()
        print("PASS: VM业务提取回归完成；未启动App/窗口/网络")
    }
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "缺少测试数据") }
        return value
    }
}