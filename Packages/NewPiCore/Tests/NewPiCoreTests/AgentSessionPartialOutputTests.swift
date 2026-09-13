import Foundation
import Testing
@testable import NewPiCore

@Suite("Session interrupted output")
struct AgentSessionPartialOutputTests {
    struct PartialProvider: LLMProvider {
        let text: String
        let thinking: String
        func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
            -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                if !thinking.isEmpty { continuation.yield(.thinkingDelta(thinking)) }
                if !text.isEmpty { continuation.yield(.textDelta(text)) }
                // 由取消结束，不自行发 completed。无需真实网络或 sleep。
            }
        }
    }
    struct CompleteProvider: LLMProvider {
        var expectedPriorText: String? = nil
        var expectedToolID: String? = nil
        func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
            -> AsyncThrowingStream<LLMStreamEvent, Error> {
            let partials = AgentSessionPartialOutputTests.assistants(messages).filter { $0.stopReason == .aborted || $0.stopReason == .error }
            #expect(partials.allSatisfy { $0.reasoningContent.isEmpty && $0.reasoningSignature.isEmpty && !$0.text.isEmpty })
            if let expectedPriorText { #expect(partials.map(\.text) == [expectedPriorText]) }
            if let expectedToolID {
                #expect(messages.contains { if case let .toolResult(result) = $0 { return result.toolCallID == expectedToolID && result.isError }; return false })
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("下一轮完成"))
                continuation.yield(.completed(stopReason: .stop, usage: UsageStats(inputTokens: 10, outputTokens: 2)))
                continuation.finish()
            }
        }
    }
    static func assistants(_ messages: [AgentMessage]) -> [AssistantMessage] {
        messages.compactMap { if case let .assistant(value) = $0 { return value }; return nil }
    }

    @Test("abort返回前部分正文和思考已保存，重启及下一轮不丢失不重复", .timeLimit(.minutes(1)))
    func abortPersistsReceivedOutput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let model = ModelConfig(provider: "fixture", modelID: "partial")
        let agent = AgentSession(context: AgentContext(systemPrompt: "test", workingDirectory: dir),
            config: AgentLoopConfig(model: model, llm: PartialProvider(text: "已输出的正文", thinking: "已输出的思考"), tools: []))
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        let events = await agent.events()
        var iterator = events.makeAsyncIterator()
        await agent.prompt("第一轮")
        while let event = await iterator.next() { if case .textDelta = event { break } }
        await agent.abort()
        let stored = try JSONLSessionStore().load(from: file)
        let partials = Self.assistants(SessionManager.messages(from: stored))
        #expect(partials.count == 1)
        #expect(partials.first?.text == "已输出的正文")
        #expect(partials.first?.reasoningContent == "已输出的思考")
        #expect(partials.first?.reasoningSignature.isEmpty == true)
        #expect(partials.first?.toolCalls.isEmpty == true)
        #expect(partials.first?.stopReason == .aborted)
        #expect(SessionManager.transcriptErrors(from: stored, leafID: stored.leafID).count == 1)
        // 不等待旧run的取消事件排空，直接继续新一轮，旧快照也不能覆盖新历史。
        await agent.updateConfig(AgentLoopConfig(model: model, llm: CompleteProvider(expectedPriorText: "已输出的正文"), tools: []))
        await agent.prompt("第二轮")
        var secondCompleted = false
        while let event = await iterator.next() {
            if case let .messageEnd(.assistant(message)) = event, message.text == "下一轮完成" { secondCompleted = true }
            if secondCompleted, case .agentEnd = event { break }
        }
        await agent.shutdown()
        let reloaded = try JSONLSessionStore().load(from: file)
        let saved = Self.assistants(SessionManager.messages(from: reloaded))
        #expect(saved.map(\.text) == ["已输出的正文", "下一轮完成"])
        #expect(saved.map(\.stopReason) == [.aborted, .stop])
        #expect(SessionManager.transcriptErrors(from: reloaded, leafID: reloaded.leafID).count == 1)
        let restored = AgentSession(context: AgentContext(systemPrompt: "test", messages: SessionManager.messages(from: reloaded), workingDirectory: dir),
            config: AgentLoopConfig(model: model, llm: CompleteProvider(), tools: []))
        await restored.attachPersistence(fileURL: file, context: reloaded)
        await restored.shutdown()
        #expect(Self.assistants(SessionManager.messages(from: try JSONLSessionStore().load(from: file))).map(\.text) == saved.map(\.text))
    }

    @Test("只有思考时取消/退出也保存，空输出不造空白回答", arguments: ["尚未完成的思考", ""], [false, true])
    func thinkingOnly(thinking: String, shutdown: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let agent = AgentSession(context: AgentContext(systemPrompt: "test", workingDirectory: dir),
            config: AgentLoopConfig(model: ModelConfig(provider: "test", modelID: "test"), llm: PartialProvider(text: "", thinking: thinking), tools: []))
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        let events = await agent.events()
        await agent.prompt("问题")
        for await event in events {
            if !thinking.isEmpty, case .thinkingDelta = event { break }
            if thinking.isEmpty, case .contextSnapshot = event { break }
        }
        if shutdown { await agent.shutdown() } else { await agent.abort() }
        let loaded = try JSONLSessionStore().load(from: file)
        let partials = Self.assistants(SessionManager.messages(from: loaded))
        #expect(partials.count == (thinking.isEmpty ? 0 : 1))
        if !thinking.isEmpty { #expect(partials.first?.reasoningContent == thinking) }
        await agent.shutdown()
    }

    struct FailingPartialProvider: LLMProvider {
        struct Failure: Error {}
        func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
            -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.thinkingDelta("失败前思考"))
                continuation.yield(.textDelta("失败前正文"))
                continuation.finish(throwing: Failure())
            }
        }
    }

    @Test("异常断流后的旧快照不能擦除部分回答")
    func failureSnapshotRetainsPartial() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let agent = AgentSession(context: AgentContext(systemPrompt: "test", workingDirectory: dir),
            config: AgentLoopConfig(model: ModelConfig(provider: "test", modelID: "test"), llm: FailingPartialProvider(), tools: []))
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        let events = await agent.events()
        await agent.prompt("问题")
        var snapshots: [AgentContext] = []
        for await event in events {
            if case let .contextSnapshot(snapshot) = event { snapshots.append(snapshot) }
            if case .agentEnd = event { break }
        }
        let loaded = try JSONLSessionStore().load(from: file)
        let partials = Self.assistants(SessionManager.messages(from: loaded))
        #expect(partials.count == 1)
        #expect(partials.first?.text == "失败前正文")
        #expect(partials.first?.reasoningContent == "失败前思考")
        #expect(partials.first?.stopReason == .error)
        #expect(Self.assistants(snapshots.last?.messages ?? []).map(\.text) == ["失败前正文"])
        await agent.shutdown()
        #expect(Self.assistants(SessionManager.messages(from: try JSONLSessionStore().load(from: file))).count == 1)
    }

    @Test("已收到完整messageEnd的回答保持完成态，不重复或改成中断")
    func completedAnswerPreserved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let agent = AgentSession(context: AgentContext(systemPrompt: "test", workingDirectory: dir),
            config: AgentLoopConfig(model: ModelConfig(provider: "test", modelID: "test"), llm: CompleteProvider(), tools: []))
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        let events = await agent.events()
        await agent.prompt("问题")
        for await event in events { if case .messageEnd(.assistant) = event { break } }
        await agent.abort()
        await agent.shutdown()
        let loaded = try JSONLSessionStore().load(from: file)
        let messages = Self.assistants(SessionManager.messages(from: loaded))
        #expect(messages.count == 1)
        #expect(messages.first?.text == "下一轮完成")
        #expect(messages.first?.stopReason == .stop)
        #expect(messages.first?.usage.outputTokens == 2)
    }

    @Test("已完成但没有结果的工具声明在下一次请求前仍由历史修复保护")
    func interruptedToolDeclarationIsRepaired() async throws {
        let history: [AgentMessage] = [.user("旧轮次"), .assistant(AssistantMessage(
            text: "准备查看文件", toolCalls: [ToolCallContent(id: "unexecuted", name: "never", arguments: .object([:]))],
            provider: "test", modelID: "test", stopReason: .toolUse))]
        let agent = AgentSession(context: AgentContext(systemPrompt: "test", messages: history),
            config: AgentLoopConfig(model: ModelConfig(provider: "test", modelID: "test"),
                llm: CompleteProvider(expectedToolID: "unexecuted"), tools: []))
        let events = await agent.events()
        await agent.prompt("新轮次")
        for await event in events { if case .agentEnd = event { break } }
        #expect(Self.assistants(await agent.context.messages).last?.text == "下一轮完成")
        await agent.shutdown()
    }
}