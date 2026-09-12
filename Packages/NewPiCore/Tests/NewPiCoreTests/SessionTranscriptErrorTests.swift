import Foundation
import Testing
@testable import NewPiCore

@Suite("Session transcript error persistence")
struct SessionTranscriptErrorTests {
    struct FixtureError: Error {}
    struct FailedProvider: LLMProvider {
        func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
            -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: FixtureError()) }
        }
    }
    struct WaitingProvider: LLMProvider {
        func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
            -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { $0.yield(.textDelta("部分输出")) }
        }
    }
    private func session(_ messages: [AgentMessage], directory: URL, provider: any LLMProvider = FailedProvider()) -> AgentSession {
        AgentSession(context: AgentContext(systemPrompt: "fixture", messages: messages, workingDirectory: directory),
            config: AgentLoopConfig(model: ModelConfig(provider: "fixture", modelID: "fixture"), llm: provider, tools: []))
    }

    @Test("取消错误在广播前落盘，新actor加载仍可读取且不进入模型消息")
    func abortReload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let messages: [AgentMessage] = [.user("第一轮")]
        let persisted = SessionContext(header: SessionHeader(workingDirectory: dir))
        let file = dir.appendingPathComponent("session.jsonl")
        let store = JSONLSessionStore()
        try store.save(persisted, to: file)
        let first = session([], directory: dir, provider: WaitingProvider())
        await first.attachPersistence(fileURL: file, context: persisted)
        let stream = await first.events()
        var iterator = stream.makeAsyncIterator()
        await first.prompt(messages[0])
        while let event = await iterator.next() { if case .textDelta = event { break } }
        let before = try store.load(from: file)
        let expectedMessages = SessionManager.messages(from: before)
        await first.abort()
        guard case .error(.aborted)? = await iterator.next() else { Issue.record("缺少取消事件"); return }
        let loaded = try store.load(from: file)
        let records = SessionManager.transcriptErrors(from: loaded, leafID: loaded.leafID)
        #expect(records.count == 1)
        #expect(records.first?.entryID == before.entries[0].id)
        #expect(records.first?.error.message == AgentError.aborted.localizedDescription)
        let restoredMessages = SessionManager.messages(from: loaded)
        #expect(Array(restoredMessages.prefix(expectedMessages.count)) == expectedMessages)
        #expect(restoredMessages.count == expectedMessages.count + 1)
        if case let .assistant(partial)? = restoredMessages.last {
            #expect(partial.text == "部分输出")
            #expect(partial.stopReason == .aborted)
        } else { Issue.record("取消应同时保存已收到的部分正文，而非仅存错误元数据") }
        #expect(try store.loadSummary(from: file).messageCount == 2)
        let restored = session(SessionManager.messages(from: loaded), directory: dir)
        await restored.attachPersistence(fileURL: file, context: loaded)
        #expect(await restored.transcriptErrors() == records)
        await restored.shutdown()
        let savedAgain = try store.load(from: file)
        #expect(SessionManager.transcriptErrors(from: savedAgain, leafID: savedAgain.leafID) == records)
        await first.shutdown()
        let afterShutdown = try store.load(from: file)
        #expect(SessionManager.transcriptErrors(from: afterShutdown, leafID: afterShutdown.leafID).count == 1)
    }

    @Test("模型错误自动保存，后续同步/压缩不覆盖错误，兄弟分支互不串入")
    func failureAndBranch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let header = SessionHeader(workingDirectory: dir)
        let agent = session([], directory: dir)
        await agent.attachPersistence(fileURL: file, header: header)
        let events = await agent.events()
        await agent.prompt("失败的一轮")
        for await event in events { if case .agentEnd = event { break } }
        let store = JSONLSessionStore()
        var loaded = try store.load(from: file)
        let records = SessionManager.transcriptErrors(from: loaded, leafID: loaded.leafID)
        #expect(records.count == 1)
        #expect(SessionManager.messages(from: loaded).count == 1)
        let firstUserID = try #require(loaded.entries.first?.id)
        var leaf = loaded.leafID
        let nextMessages = SessionManager.messages(from: loaded) + [.user("下一轮")]
        SessionManager.syncMessages(nextMessages, into: &loaded, leafID: &leaf)
        #expect(SessionManager.transcriptErrors(from: loaded, leafID: leaf) == records)
        let secondUserID = try #require(leaf)
        loaded.entries[loaded.entries.count - 1].transcriptErrors = [SessionTranscriptError(message: "第二轮错误")]
        var forked = try SessionManager.forkContext(loaded, at: firstUserID)
        var forkLeaf = forked.leafID
        SessionManager.syncMessages([.user("失败的一轮"), .user("兄弟分支")], into: &forked, leafID: &forkLeaf)
        try store.save(forked, to: file)
        let reloaded = try store.load(from: file)
        #expect(SessionManager.transcriptErrors(from: reloaded, leafID: reloaded.leafID) == records)
        #expect(SessionManager.transcriptErrors(from: reloaded, leafID: secondUserID).count == 2)
        let compactedMessages: [AgentMessage] = [.compactionSummary("摘要"), .user("压缩后新一轮")]
        SessionManager.syncMessages(compactedMessages, into: &loaded, leafID: &leaf)
        #expect(SessionManager.messages(from: loaded) == compactedMessages)
        #expect(SessionManager.transcriptErrors(from: loaded, leafID: leaf).count == 2)
        await agent.shutdown()
    }

    @Test("旧版无错误元数据的JSONL仍可解码")
    func legacyDecode() throws {
        let context = SessionManager.rebuildContext(from: [.user("旧会话")], header: SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp")))
        let codec = JSONLSessionCodec()
        let data = try codec.encode(context)
        #expect(!String(decoding: data, as: UTF8.self).contains("transcriptErrors"))
        let loaded = try codec.decode(data)
        #expect(loaded.entries.first?.transcriptErrors == nil)
        #expect(SessionManager.transcriptErrors(from: loaded, leafID: loaded.leafID).isEmpty)
    }

    @Test("错误首次写盘失败后，shutdown重试保留元数据")
    func diskFailureRetry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let agent = session([], directory: dir, provider: WaitingProvider())
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        let events = await agent.events()
        await agent.prompt("磁盘重试")
        for await event in events { if case .textDelta = event { break } }
        let backup = dir.appendingPathComponent("backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await agent.abort()
        #expect(await agent.transcriptErrors().count == 1)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        await agent.shutdown()
        let reloaded = try JSONLSessionStore().load(from: file)
        #expect(SessionManager.transcriptErrors(from: reloaded, leafID: reloaded.leafID).count == 1)
    }

    @Test("不同轮次同一错误各自保存，不按文字跨轮去重")
    func separateRuns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let agent = session([], directory: dir)
        await agent.attachPersistence(fileURL: file, header: SessionHeader(workingDirectory: dir))
        let events = await agent.events()
        var iterator = events.makeAsyncIterator()
        for prompt in ["A", "B"] {
            await agent.prompt(prompt)
            while let event = await iterator.next() { if case .agentEnd = event { break } }
        }
        let loaded = try JSONLSessionStore().load(from: file)
        let errors = SessionManager.transcriptErrors(from: loaded, leafID: loaded.leafID)
        #expect(errors.count == 2)
        #expect(Set(errors.map(\.entryID)).count == 2)
        #expect(Set(errors.map(\.error.id)).count == 2)
        await agent.shutdown()
    }

    @Test("新一轮立即取消不能把错误写到上一轮")
    func immediateAbortDoesNotUsePreviousTurn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let prior: [AgentMessage] = [.user("原轮次")]
        let saved = SessionManager.rebuildContext(from: prior, header: SessionHeader(workingDirectory: dir))
        try JSONLSessionStore().save(saved, to: file)
        let agent = session(prior, directory: dir, provider: WaitingProvider())
        await agent.attachPersistence(fileURL: file, context: saved)
        await agent.prompt("立即取消的新轮次")
        await agent.abort()
        await agent.shutdown()
        let loaded = try JSONLSessionStore().load(from: file)
        #expect(loaded.entries.first?.transcriptErrors?.isEmpty != false)
        // 新轮次若尚未形成快照，可无记录；但绝不借用上一轮作为错误归属。
        #expect(SessionManager.transcriptErrors(from: loaded, leafID: loaded.leafID).allSatisfy { $0.entryID != saved.entries.first?.id })
    }
}