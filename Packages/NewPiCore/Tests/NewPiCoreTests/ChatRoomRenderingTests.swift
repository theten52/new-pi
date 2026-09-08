import Foundation
import Testing
@testable import NewPiCore

@Suite("ChatRoom speech buffering")
@MainActor
struct ChatRoomSpeechBufferTests {
    private func fixture() -> (ChatRoomRuntime, ChatRoomSpeechBuffer, ChatRoomMessage) {
        let room = ChatRoom(name: "test", roles: [], projectPath: "/tmp")
        let runtime = ChatRoomRuntime(chatroom: room)
        let speech = UUID().uuidString
        let message = ChatRoomMessage(chatroomID: room.id, roleID: "agent", content: "", speechID: speech, phase: .discussion)
        let buffer = ChatRoomSpeechBuffer(runtime: runtime, speechID: speech, interval: .milliseconds(30))
        buffer.beginSegment(message)
        return (runtime, buffer, message)
    }

    @Test("tail flushes without another model event")
    func idleTail() async throws {
        let (runtime, buffer, _) = fixture()
        defer { buffer.finish() }
        buffer.appendText("first")
        buffer.appendText(" tail")
        // 第一次立即显示；即便没有再来事件，剩余字符也有定时冲刷。
        for _ in 0..<100 where runtime.messages[0].content != "first tail" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(runtime.messages[0].content == "first tail")
    }

    @Test("steering does not change current segment or streaming identity")
    func steeringIdentity() {
        let (runtime, buffer, message) = fixture()
        defer { buffer.finish() }
        buffer.appendThinking("reasoning")
        runtime.messages.append(ChatRoomMessage(chatroomID: runtime.chatroom.id, roleID: "user", content: "steering", phase: .discussion))
        buffer.appendText("answer")
        buffer.flush()
        #expect(runtime.liveSpeech?.messageID == message.id)
        #expect(runtime.liveSpeech?.phase == .text)
        #expect(runtime.messages[0].content == "answer")
        #expect(runtime.messages[0].reasoningContent == "reasoning")
        #expect(runtime.messages[1].content == "steering")
    }

    @Test("completion freezes the message while the speech remains active")
    func messageCompletion() {
        let (runtime, buffer, message) = fixture()
        buffer.appendThinking("reason")
        buffer.appendText("tail")
        buffer.completeMessage()
        #expect(runtime.messages[0].content == "tail")
        #expect(runtime.liveSpeech?.messageID == message.id)
        #expect(runtime.liveSpeech?.phase == .complete)
        buffer.finish()
        #expect(runtime.liveSpeech == nil)
    }

    @Test("approval callback waits for consumed boundary and cannot hang after cancellation")
    func approvalGate() async throws {
        let gate = ChatRoomApprovalEventGate()
        let first = Task { await gate.wait(for: "first") }
        await Task.yield()
        gate.reach("first")
        #expect(await first.value)
        gate.reach("early")
        #expect(await gate.wait(for: "early"))
        let cancelled = Task { await gate.wait(for: "cancelled") }
        await Task.yield()
        cancelled.cancel()
        #expect(await cancelled.value == false)
        let pending = Task { await gate.wait(for: "pending") }
        await Task.yield()
        gate.finish()
        #expect(await pending.value == false)
        #expect(await gate.wait(for: "late") == false)
    }

    @Test("segment boundary and finish cannot leak delayed text to the next turn")
    func segmentBoundary() async throws {
        let (runtime, buffer, message) = fixture()
        buffer.appendText("a")
        buffer.appendText("b")
        let next = ChatRoomMessage(chatroomID: runtime.chatroom.id, roleID: "agent", content: "", speechID: message.speechID, phase: .discussion)
        buffer.beginSegment(next)
        buffer.appendText("c")
        buffer.appendText("d")
        buffer.finish()
        try await Task.sleep(for: .milliseconds(80))
        #expect(runtime.messages.map(\.content) == ["ab", "cd"])
        #expect(runtime.liveSpeech == nil)
    }
}

/// 手动生产事件，不访问网络；测试可以精确停在正文/工具/审批边界。
private final class ControlledChatRoomLLM: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation?

    func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { next in
            lock.lock(); continuation = next; lock.unlock()
        }
    }
    var ready: Bool {
        lock.lock(); defer { lock.unlock() }; return continuation != nil
    }
    func fail() {
        struct ProviderFailure: Error {}
        lock.lock(); let c = continuation; lock.unlock()
        c?.finish(throwing: ProviderFailure())
    }
    func emit(_ events: [LLMStreamEvent], finish: Bool = false) {
        lock.lock(); let c = continuation; lock.unlock()
        for event in events { c?.yield(event) }
        if finish { c?.finish() }
    }
}

@Suite("ChatRoom rendering integration")
@MainActor
struct ChatRoomRenderingIntegrationTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "timed out waiting for deterministic model event")
        throw WaitTimeout()
    }
    private struct WaitTimeout: Error {}

    private func fixture(llm: ControlledChatRoomLLM) throws -> (ChatRoomLoop, ChatRoomRuntime, ChatRoomStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("render-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let role = ChatRoomRole(name: "role", description: "", systemPrompt: "", providerProfileID: "mock", modelID: "mock")
        let room = ChatRoom(name: "test", roles: [role], projectPath: dir.path)
        let store = ChatRoomStore(baseDirectory: dir.appendingPathComponent("store"))
        try store.save(room)
        let loop = ChatRoomLoop(store: store, engineProvider: { _ in
            ChatRoomRoleEngine(llm: llm, model: ModelConfig(provider: "mock", modelID: "mock"))
        })
        return (loop, ChatRoomRuntime(chatroom: room), store, dir)
    }

    @Test("steering retains streaming identity and reload preserves on-screen message order")
    func steeringReload() async throws {
        let llm = ControlledChatRoomLLM()
        let (loop, runtime, store, dir) = try fixture(llm: llm)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task { try await loop.triggerNextSpeaker(runtime: runtime) }
        defer { task.cancel() }
        try await wait { llm.ready }
        llm.emit([.textDelta("first")])
        try await wait { runtime.messages.first?.content == "first" }
        let messageID = runtime.liveSpeech?.messageID
        try loop.userSpeak(content: "user interruption", runtime: runtime)
        llm.emit([.textDelta(" tail")])
        try await wait { runtime.messages.first?.content == "first tail" }
        #expect(runtime.liveSpeech?.messageID == messageID)
        #expect(runtime.liveSpeech?.phase == .text)
        #expect(runtime.messages.last?.isUserMessage == true)
        llm.emit([.completed(stopReason: .stop, usage: UsageStats())], finish: true)
        try await task.value
        #expect(runtime.liveSpeech == nil)
        #expect(!runtime.isRunning)
        let disk = try store.loadMessages(for: runtime.chatroom.id)
        #expect(disk.map(\.id) == runtime.messages.map(\.id))
        #expect(disk.map(\.content) == ["first tail", "user interruption"])
    }

    @Test("cancelling buffered output keeps partial text and thinking with a persistent marker")
    func cancelPartial() async throws {
        let llm = ControlledChatRoomLLM()
        let (loop, runtime, store, dir) = try fixture(llm: llm)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task { try await loop.triggerNextSpeaker(runtime: runtime) }
        defer { task.cancel() }
        try await wait { llm.ready }
        llm.emit([.thinkingDelta("reason"), .textDelta("partial")])
        try await wait { runtime.liveSpeech?.phase == .text }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runtime.messages.first?.content == "partial")
        #expect(runtime.messages.first?.reasoningContent == "reason")
        #expect(runtime.messages.first?.termination == .cancelled)
        #expect(runtime.liveSpeech == nil && !runtime.isRunning)
        #expect(runtime.currentSpeakerIndex == 0)
        let disk = try store.loadMessages(for: runtime.chatroom.id)
        #expect(disk.first?.id == runtime.messages.first?.id)
        #expect(disk.first?.termination == .cancelled)
        #expect(ChatRoomContextBuilder.buildAgentContext(room: runtime.chatroom, history: disk).contains {
            if case .assistant(let message) = $0 { return message.text.contains("未完成") }
            return false
        })
    }

    @Test("approval sees flushed tail, cancellation keeps the tool with an honest unknown outcome")
    func approvalBoundary() async throws {
        let llm = ControlledChatRoomLLM()
        let (loop, runtime, store, dir) = try fixture(llm: llm)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task { try await loop.triggerNextSpeaker(runtime: runtime) }
        defer { task.cancel() }
        try await wait { llm.ready }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("approval-check-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        llm.emit([.textDelta("prepare"), .textDelta(" to run"),
            .toolCall(ToolCallContent(id: "test-tool", name: "write", arguments: .object([
                "path": .string(outside.path), "content": .string("test")
            ]))),
            .completed(stopReason: .toolUse, usage: UsageStats())], finish: true)
        try await wait { !loop.approvalManager.pendingApprovals.isEmpty }
        #expect(runtime.messages.first?.content == "prepare to run")
        try await wait { runtime.liveSpeech?.phase == .complete }
        #expect(runtime.messages.first?.toolCalls?.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await wait { loop.approvalManager.pendingApprovals.isEmpty }
        let disk = try store.loadMessages(for: runtime.chatroom.id)
        #expect(disk.first?.termination == .cancelled)
        #expect(disk.first?.toolCalls?.count == 1)
        #expect(disk.first?.toolResults?.first?.isError == true)
        #expect(disk.first?.toolResults?.first?.output.contains("未收到") == true)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        // 未批准，不实际写入。
    }

    @Test("provider failure retains already visible output instead of silently discarding it")
    func failedPartial() async throws {
        let llm = ControlledChatRoomLLM()
        let (loop, runtime, store, dir) = try fixture(llm: llm)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task { try await loop.triggerNextSpeaker(runtime: runtime) }
        defer { task.cancel() }
        try await wait { llm.ready }
        llm.emit([.textDelta("partial answer")])
        try await wait { runtime.messages.first?.content == "partial answer" }
        llm.fail()
        try await task.value
        #expect(runtime.messages.first?.content.contains("partial answer") == true)
        #expect(runtime.messages.first?.termination == .failed)
        #expect(runtime.messages.first?.candidates == nil)
        #expect(try store.loadMessages(for: runtime.chatroom.id).first?.termination == .failed)
        #expect(runtime.liveSpeech == nil)
    }

    private struct InterruptedLegacyProvider: ChatRoomLLMProvider {
        func chat(systemPrompt: String, messages: [ChatRoomLLMMessage]) async throws -> ChatRoomLLMResponse {
            throw CancellationError()
        }
        func chatWithEvents(systemPrompt: String, messages: [ChatRoomLLMMessage],
            onEvent: (@MainActor @Sendable (ChatRoomSpeechEvent) -> Void)?
        ) async throws -> ChatRoomLLMResponse {
            await onEvent?(.thinkingDelta("legacy reasoning"))
            await onEvent?(.textDelta("legacy text"))
            await onEvent?(.toolStarted(ChatRoomToolCall(id: "known", name: "read_file", arguments: "{}")))
            await onEvent?(.toolFinished(ChatRoomToolResult(toolCallID: "known", output: "actual result")))
            await onEvent?(.toolStarted(ChatRoomToolCall(id: "unknown", name: "write_file", arguments: "{}")))
            throw CancellationError()
        }
    }
    private struct LegacyFactory: ChatRoomLLMProviderFactory {
        func createProvider(profileID: String, modelID: String, projectPath: String,
            roleID: String, roleName: String, thinkingLevel: ThinkingLevel?
        ) throws -> any ChatRoomLLMProvider { InterruptedLegacyProvider() }
    }

    @Test("legacy provider cancellation preserves known results and marks unknown ones")
    func legacyCancellation() async throws {
        let (unusedLoop, runtime, store, dir) = try fixture(llm: ControlledChatRoomLLM())
        _ = unusedLoop
        defer { try? FileManager.default.removeItem(at: dir) }
        let loop = ChatRoomLoop(store: store, llmFactory: LegacyFactory())
        await #expect(throws: CancellationError.self) { try await loop.triggerNextSpeaker(runtime: runtime) }
        let disk = try store.loadMessages(for: runtime.chatroom.id)
        #expect(disk.count == 1)
        #expect(disk.first?.content == "legacy text")
        #expect(disk.first?.reasoningContent == "legacy reasoning")
        #expect(disk.first?.termination == .cancelled)
        #expect(disk.first?.toolResults?.first?.output == "actual result")
        #expect(disk.first?.toolResults?.last?.output.contains("未收到") == true)
        #expect(runtime.liveSpeech == nil && !runtime.isRunning)
    }

    @Test("message decoding stays compatible with records without termination metadata")
    func legacyDecode() throws {
        let message = ChatRoomMessage(chatroomID: "room", roleID: "agent", content: "old", phase: .discussion)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatRoomMessage.self, from: data)
        #expect(decoded.termination == nil)
    }
}
