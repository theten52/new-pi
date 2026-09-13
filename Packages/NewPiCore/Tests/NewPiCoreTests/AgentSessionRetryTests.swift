import Foundation
import Testing
@testable import NewPiCore

@Suite("Session safe retry", .timeLimit(.minutes(1)))
struct AgentSessionRetryTests {
    /// 无网络脚本；记录实际 provider 请求上下文，而不是只检查 UI 状态。
    final class Provider: LLMProvider, @unchecked Sendable {
        enum Step { case tool, fail, success, wait }
        private let lock = NSLock()
        private var steps: [Step]
        private var requests: [[AgentMessage]] = []
        private var waiting: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation?
        init(_ steps: [Step]) { self.steps = steps }
        var calls: [[AgentMessage]] { lock.withLock { requests } }
        func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
            -> AsyncThrowingStream<LLMStreamEvent, Error> {
            let step = lock.withLock { () -> Step in
                requests.append(messages)
                return steps.isEmpty ? .success : steps.removeFirst()
            }
            return AsyncThrowingStream { continuation in
                switch step {
                case .tool:
                    continuation.yield(.toolCall(ToolCallContent(id: "done-tool", name: "retry_fixture", arguments: .object([:]))))
                    continuation.yield(.completed(stopReason: .toolUse, usage: UsageStats()))
                    continuation.finish()
                case .fail:
                    continuation.yield(.thinkingDelta("未完成的思考"))
                    continuation.yield(.textDelta("保留的部分输出"))
                    continuation.finish(throwing: URLError(.timedOut))
                case .success:
                    continuation.yield(.textDelta("恢复后的回答"))
                    continuation.yield(.completed(stopReason: .stop, usage: UsageStats()))
                    continuation.finish()
                case .wait:
                    lock.withLock { waiting = continuation }
                    continuation.yield(.textDelta("等待重试响应"))
                }
            }
        }
        func finishWaiting() {
            let continuation = lock.withLock { let value = waiting; waiting = nil; return value }
            continuation?.yield(.completed(stopReason: .stop, usage: UsageStats()))
            continuation?.finish()
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }
    struct Tool: AgentTool {
        let counter: Counter
        let name = "retry_fixture"
        var definition: ToolDefinition {
            ToolDefinition(name: name, description: "纯计数测试工具", parameters: .object(["type": .string("object")]))
        }
        func execute(id: String, arguments: JSONValue, context: ToolContext,
                     onUpdate: (@Sendable (ToolProgress) -> Void)?) async throws -> ToolResult {
            counter.increment()
            return ToolResult(content: "真实工具结果")
        }
    }

    private func session(provider: Provider, directory: URL, messages: [AgentMessage] = [], counter: Counter = Counter()) -> AgentSession {
        AgentSession(context: AgentContext(systemPrompt: "fixture", messages: messages, workingDirectory: directory),
            config: AgentLoopConfig(model: ModelConfig(provider: "fixture-provider", modelID: "fixture-model"),
                llm: provider, tools: [Tool(counter: counter)]))
    }
    private func finish(_ iterator: inout AsyncStream<AgentEvent>.Iterator) async {
        while let event = await iterator.next() { if case .agentEnd = event { return } }
    }
    private func userCount(_ messages: [AgentMessage]) -> Int {
        messages.filter { if case .user = $0 { return true }; return false }.count
    }

    @Test("失败→真实调用成功：保留用户/部分输出/工具结果，工具只执行一次", arguments: [false, true])
    func retryWithContext(cold: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let provider = Provider([.tool, .fail, .success])
        let counter = Counter()
        var agent = session(provider: provider, directory: dir, counter: counter)
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        var iterator = await agent.events().makeAsyncIterator()
        await agent.prompt("只发一次的用户消息")
        await finish(&iterator)
        let record = try #require(await agent.transcriptErrors().last)
        #expect(record.error.retryState == "available")
        #expect(record.error.errorTitle == "连接超时")
        #expect(record.error.provider == "fixture-provider")
        #expect(record.error.modelID == "fixture-model")
        #expect(counter.count == 1)
        #expect(provider.calls.count == 2)
        if cold {
            await agent.shutdown()
            let loaded = try JSONLSessionStore().load(from: file)
            agent = session(provider: provider, directory: dir, messages: SessionManager.messages(from: loaded), counter: counter)
            await agent.attachPersistence(fileURL: file, context: loaded)
            iterator = await agent.events().makeAsyncIterator()
            let restored = try #require(await agent.transcriptErrors().last)
            #expect(restored.entryID == record.entryID)
            #expect(restored.error.id == record.error.id)
            #expect(restored.error.retryState == "available")
            #expect(restored.error.retryLeafID == record.error.retryLeafID)
            // JSONL 日期编码精度与内存 Date 不同，身份/锚点必须精确，时间按秒校验。
            #expect(abs(restored.error.timestamp.timeIntervalSince(record.error.timestamp)) < 1)
        }
        let historyBeforeRetry = await agent.context.messages
        let diskBeforeRetry = SessionManager.messages(from: try JSONLSessionStore().load(from: file))
        try await agent.retry(errorID: record.error.id)
        await finish(&iterator)
        #expect(provider.calls.count == 3)
        #expect(provider.calls.allSatisfy { userCount($0) == 1 })
        #expect(counter.count == 1)
        let retryInput = try #require(provider.calls.last)
        #expect(retryInput.contains { if case let .toolResult(result) = $0 { return result.content == "真实工具结果" && !result.isError }; return false })
        #expect(retryInput.last?.roleLabel == "toolResult")
        #expect(retryInput == Array(historyBeforeRetry.dropLast()))
        #expect(!retryInput.contains { if case let .assistant(value) = $0 { return value.text == "保留的部分输出" }; return false })
        let messages = await agent.context.messages
        #expect(userCount(messages) == 1)
        #expect(Array(messages.prefix(historyBeforeRetry.count)) == historyBeforeRetry)
        #expect(messages.contains { if case let .assistant(value) = $0 { return value.text == "保留的部分输出" && value.reasoningContent == "未完成的思考" && value.stopReason == .error }; return false })
        #expect(await agent.transcriptErrors().last?.error.retryState == "recovered")
        let loaded = try JSONLSessionStore().load(from: file)
        #expect(Array(SessionManager.messages(from: loaded).prefix(diskBeforeRetry.count)) == diskBeforeRetry)
        #expect(SessionManager.transcriptErrors(from: loaded, leafID: loaded.leafID).last?.error.retryState == "recovered")
        await #expect(throws: AgentError.self) { try await agent.retry(errorID: record.error.id) }
        await agent.shutdown()
    }

    @Test("双击拒绝，retrying落盘，再失败生成最新锚点")
    func doubleClickAndFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let provider = Provider([.fail, .wait, .fail])
        let agent = session(provider: provider, directory: dir)
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        var iterator = await agent.events().makeAsyncIterator()
        await agent.prompt("问题")
        await finish(&iterator)
        let first = try #require(await agent.transcriptErrors().last)
        try await agent.retry(errorID: first.error.id)
        await #expect(throws: AgentError.self) { try await agent.retry(errorID: first.error.id) }
        while let event = await iterator.next() { if case .textDelta = event { break } }
        #expect(provider.calls.count == 2)
        let saved = try JSONLSessionStore().load(from: file)
        #expect(SessionManager.transcriptErrors(from: saved, leafID: saved.leafID).last?.error.retryState == "retrying")
        let cold = session(provider: Provider([]), directory: dir, messages: SessionManager.messages(from: saved))
        await cold.attachPersistence(fileURL: file, context: saved)
        #expect(await cold.transcriptErrors().last?.error.retryState == "unavailable")
        await #expect(throws: AgentError.self) { try await cold.retry(errorID: first.error.id) }
        provider.finishWaiting()
        await finish(&iterator)
        await agent.prompt("新一轮")
        await finish(&iterator)
        await #expect(throws: AgentError.self) { try await agent.retry(errorID: first.error.id) }
        let latest = try #require(await agent.transcriptErrors().last)
        #expect(latest.error.id != first.error.id)
        #expect(latest.error.retryState == "available")
        await agent.shutdown()
    }

    @Test("重试再次失败仍为failed，旧卡不假称recovered；连续partial仅在请求尾部移除", arguments: [false, true])
    func retryFailsAgain(withTools: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let provider = Provider(withTools ? [.tool, .fail, .fail, .success] : [.fail, .fail, .success])
        let counter = Counter()
        let agent = session(provider: provider, directory: dir, counter: counter)
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        var iterator = await agent.events().makeAsyncIterator()
        await agent.prompt("问题")
        await finish(&iterator)
        let firstHistory = await agent.context.messages
        let expectedInput = Array(firstHistory.dropLast())
        let id = try #require(await agent.transcriptErrors().last?.error.id)
        try await agent.retry(errorID: id)
        await finish(&iterator)
        let records = await agent.transcriptErrors()
        #expect(records.map(\.error.retryState) == ["unavailable", "available"])
        #expect(userCount(await agent.context.messages) == 1)
        #expect(provider.calls.last == expectedInput)
        let failedHistory = await agent.context.messages
        #expect(Array(failedHistory.prefix(firstHistory.count)) == firstHistory)
        #expect(failedHistory.count == firstHistory.count + 1)
        let failedPartials = failedHistory.compactMap { message -> AssistantMessage? in
            if case let .assistant(value) = message, value.stopReason == .error { return value }
            return nil
        }
        #expect(failedPartials.count == 2)
        #expect(failedPartials.allSatisfy { $0.text == "保留的部分输出" && $0.reasoningContent == "未完成的思考" })
        let diskBeforeRetry = SessionManager.messages(from: try JSONLSessionStore().load(from: file))
        let latestID = try #require(records.last?.error.id)
        try await agent.retry(errorID: latestID)
        await finish(&iterator)
        #expect(await agent.transcriptErrors().last?.error.retryState == "recovered")
        #expect(provider.calls.count == (withTools ? 4 : 3))
        #expect(provider.calls.allSatisfy { userCount($0) == 1 })
        #expect(provider.calls.last == expectedInput)
        #expect(provider.calls.last?.last?.roleLabel == (withTools ? "toolResult" : "user"))
        #expect(counter.count == (withTools ? 1 : 0))
        let recoveredHistory = await agent.context.messages
        #expect(userCount(recoveredHistory) == 1)
        #expect(Array(recoveredHistory.prefix(failedHistory.count)) == failedHistory)
        #expect(recoveredHistory.count == failedHistory.count + 1)
        let saved = try JSONLSessionStore().load(from: file)
        #expect(Array(SessionManager.messages(from: saved).prefix(diskBeforeRetry.count)) == diskBeforeRetry)
        #expect(userCount(SessionManager.messages(from: saved)) == 1)
        await agent.shutdown()
    }

    @Test("resume移除混合error/aborted尾部，不越过用户或完整工具结果", arguments: [false, true])
    func resumeMixedInterruptedTail(withTools: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let partials: [AgentMessage] = [
            .assistant(AssistantMessage(text: "失败正文", reasoningContent: "失败思考", reasoningSignature: "失败签名",
                provider: "fixture", modelID: "fixture", stopReason: .error)),
            .assistant(AssistantMessage(text: "取消正文", reasoningContent: "取消思考", reasoningSignature: "取消签名",
                provider: "fixture", modelID: "fixture", stopReason: .aborted)),
            .assistant(AssistantMessage(text: "", reasoningContent: "只有思考",
                provider: "fixture", modelID: "fixture", stopReason: .error))
        ]
        var boundary: [AgentMessage] = [.user("问题")]
        if withTools {
            // 边界之前的 partial 仍按既有规则投影；完整工具声明及结果不能丢失。
            boundary.append(partials[0])
            boundary.append(.assistant(AssistantMessage(text: "", toolCalls: [
                ToolCallContent(id: "done-tool", name: "retry_fixture", arguments: .object([:]))
            ], provider: "fixture", modelID: "fixture", stopReason: .toolUse)))
            boundary.append(.toolResult(ToolResultMessage(toolCallID: "done-tool", toolName: "retry_fixture",
                content: "真实工具结果", isError: false)))
        }
        let history = boundary + partials
        var expectedInput = boundary
        if withTools, case var .assistant(value) = expectedInput[1] {
            value.reasoningContent = ""
            value.reasoningSignature = ""
            expectedInput[1] = .assistant(value)
        }
        let provider = Provider([.success])
        let counter = Counter()
        let config = AgentLoopConfig(model: ModelConfig(provider: "fixture", modelID: "fixture"),
            llm: provider, tools: [Tool(counter: counter)])
        var snapshot: AgentContext?
        for await event in AgentLoop().resume(context: AgentContext(systemPrompt: "fixture", messages: history, workingDirectory: dir), config: config) {
            if case let .contextSnapshot(value) = event { snapshot = value }
        }
        #expect(provider.calls == [expectedInput])
        #expect(provider.calls.last?.last?.roleLabel == (withTools ? "toolResult" : "user"))
        #expect(counter.count == 0)
        let finalHistory = try #require(snapshot).messages
        #expect(Array(finalHistory.prefix(history.count)) == history)
        #expect(finalHistory.count == history.count + 1)
    }

    @Test("resume仅首轮裁尾，后续工具请求与普通next-user保留partial正文", arguments: [false, true])
    func partialRemainsOutsideFirstResumeRequest(retry: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider(retry ? [.fail, .tool, .success] : [.fail, .success])
        let counter = Counter()
        let agent = session(provider: provider, directory: dir, counter: counter)
        await agent.attachPersistence(fileURL: dir.appendingPathComponent("session.jsonl"), header: SessionHeader(workingDirectory: dir))
        var iterator = await agent.events().makeAsyncIterator()
        await agent.prompt("问题")
        await finish(&iterator)
        let failedHistory = await agent.context.messages
        if retry {
            let id = try #require(await agent.transcriptErrors().last?.error.id)
            try await agent.retry(errorID: id)
        } else {
            await agent.prompt("新问题")
        }
        await finish(&iterator)
        #expect(provider.calls.count == (retry ? 3 : 2))
        if retry {
            #expect(provider.calls[1] == Array(failedHistory.prefix(1)))
        }
        let input = try #require(provider.calls.last)
        #expect(input.last?.roleLabel == (retry ? "toolResult" : "user"))
        #expect(userCount(input) == (retry ? 1 : 2))
        #expect(input.contains { if case let .assistant(value) = $0 {
            return value.text == "保留的部分输出" && value.reasoningContent.isEmpty && value.reasoningSignature.isEmpty && value.stopReason == .error
        }; return false })
        #expect(counter.count == (retry ? 1 : 0))
        let finalHistory = await agent.context.messages
        #expect(Array(finalHistory.prefix(failedHistory.count)) == failedHistory)
        await agent.shutdown()
    }

    @Test("冷恢复拒绝未完成工具、旧锚点和旧格式错误", arguments: ["pending", "stale", "legacy"])
    func unsafeColdRetry(mode: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var messages: [AgentMessage] = [.user("问题")]
        if mode == "pending" {
            messages.append(.assistant(AssistantMessage(text: "", toolCalls: [ToolCallContent(id: "pending", name: "retry_fixture", arguments: .object([:]))],
                provider: "fixture", modelID: "fixture", stopReason: .toolUse)))
        }
        var saved = SessionManager.rebuildContext(from: messages, header: SessionHeader(workingDirectory: dir))
        let error = SessionTranscriptError(message: "失败", retryState: mode == "legacy" ? nil : "available",
            retryLeafID: mode == "stale" ? "旧叶节点" : saved.leafID)
        saved.entries[0].transcriptErrors = [error]
        let provider = Provider([])
        let agent = session(provider: provider, directory: dir, messages: messages)
        await agent.attachPersistence(fileURL: dir.appendingPathComponent("session.jsonl"), context: saved)
        await #expect(throws: AgentError.self) { try await agent.retry(errorID: error.id) }
        #expect(provider.calls.isEmpty)
    }

    @Test("取消不能重试；错误分类不把普通异常说成网络故障")
    func cancellationAndClassification() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = Provider([.wait])
        let agent = session(provider: provider, directory: dir)
        await agent.attachPersistence(fileURL: dir.appendingPathComponent("session.jsonl"), header: SessionHeader(workingDirectory: dir))
        var iterator = await agent.events().makeAsyncIterator()
        await agent.prompt("问题")
        while let event = await iterator.next() { if case .textDelta = event { break } }
        await agent.abort()
        let error = try #require(await agent.transcriptErrors().last?.error)
        #expect(error.retryState == "unavailable")
        #expect(error.errorTitle == "已停止")
        await #expect(throws: AgentError.self) { try await agent.retry(errorID: error.id) }
        #expect(AgentError.llmFailed("HTTP 401").transcriptTitle == "身份验证失败")
        #expect(AgentError.llmFailed("HTTP 503").transcriptTitle == "服务请求失败")
        #expect(AgentError.llmFailed("decode failed").transcriptTitle == "模型请求失败")
        provider.finishWaiting()
        await agent.shutdown()
    }

    @Test("没有原始已接受user的失败不能领取重试，旧错误元数据缺省nil")
    func noAcceptedUser() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = session(provider: Provider([.fail]), directory: dir)
        await agent.attachPersistence(fileURL: dir.appendingPathComponent("session.jsonl"), header: SessionHeader(workingDirectory: dir))
        var iterator = await agent.events().makeAsyncIterator()
        await agent.prompt(.compactionSummary("无用户锚点"))
        await finish(&iterator)
        #expect(await agent.transcriptErrors().isEmpty)
        await #expect(throws: AgentError.self) { try await agent.retry(errorID: UUID()) }
        let old = SessionTranscriptError(message: "旧错误")
        let decoded = try JSONDecoder().decode(SessionTranscriptError.self, from: JSONEncoder().encode(old))
        #expect(decoded.retryState == nil && decoded.provider == nil && decoded.modelID == nil && decoded.errorTitle == nil)
        await agent.shutdown()
    }

    @Test("无法持久化retrying时不启动provider")
    func retryClaimMustPersist() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let provider = Provider([.fail, .success])
        let agent = session(provider: provider, directory: dir)
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        var iterator = await agent.events().makeAsyncIterator()
        await agent.prompt("问题")
        await finish(&iterator)
        let id = try #require(await agent.transcriptErrors().last?.error.id)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: AgentError.self) { try await agent.retry(errorID: id) }
        #expect(provider.calls.count == 1)
        #expect(await agent.transcriptErrors().last?.error.retryState == "unavailable")
        try FileManager.default.removeItem(at: file)
        await agent.shutdown()
    }
}