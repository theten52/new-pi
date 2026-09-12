import Foundation
import Testing
@testable import NewPiCore

/// 手动推进真实 loop 的流，不访问网络、用户配置或用户会话。
private final class SnapshotControlledLLM: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<LLMStreamEvent, Error>.Continuation] = []
    private var models: [ModelConfig] = []

    func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage],
                tools: [ToolDefinition]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            models.append(model)
            continuations.append(continuation)
            lock.unlock()
        }
    }

    var requestedModels: [ModelConfig] {
        lock.lock(); defer { lock.unlock() }
        return models
    }

    func emit(_ events: [LLMStreamEvent], request: Int = 0, finish: Bool = false) {
        lock.lock(); let continuation = continuations[request]; lock.unlock()
        for event in events { continuation.yield(event) }
        if finish { continuation.finish() }
    }

    func fail(_ error: any Error, request: Int = 0) {
        lock.lock(); let continuation = continuations[request]; lock.unlock()
        continuation.finish(throwing: error)
    }
}

private struct SnapshotLegacyFactory: ChatRoomLLMProviderFactory {
    let llm: SnapshotControlledLLM
    let model: ModelConfig
    let approvalManager: ChatRoomApprovalManager

    func createProvider(profileID: String, modelID: String, projectPath: String,
                        roleID: String, roleName: String, thinkingLevel: ThinkingLevel?) throws -> any ChatRoomLLMProvider {
        ChatRoomLLMProviderImpl(provider: llm, modelConfig: model,
            toolExecutor: ChatRoomToolExecutor(projectPath: projectPath, approvalManager: approvalManager,
                roleID: roleID, roleName: roleName))
    }
}

@Suite("聊天室历史模型快照")
@MainActor
struct ChatRoomModelSnapshotTests {
    @MainActor
    private struct Fixture {
        let directory: URL
        let store: ChatRoomStore
        let runtime: ChatRoomRuntime
        let approval: ChatRoomApprovalManager

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("room-model-\(UUID().uuidString)")
            store = ChatRoomStore(baseDirectory: directory)
            let roles = ["A", "B"].map {
                ChatRoomRole(id: $0, name: $0, description: "", systemPrompt: "",
                    providerProfileID: "profile-not-provider-\($0)", modelID: "role-not-model-\($0)")
            }
            let room = ChatRoom(name: "模型快照测试", roles: roles, projectPath: directory.path)
            runtime = ChatRoomRuntime(chatroom: room)
            approval = ChatRoomApprovalManager(policyStore: ApprovalPolicyStore(
                fileURL: directory.appendingPathComponent("isolated-policy.json")))
            try store.save(room)
        }

        func loop(llm: SnapshotControlledLLM, model: ModelConfig, legacy: Bool) -> ChatRoomLoop {
            if legacy {
                return ChatRoomLoop(store: store,
                    llmFactory: SnapshotLegacyFactory(llm: llm, model: model, approvalManager: approval),
                    approvalManager: approval)
            }
            return ChatRoomLoop(store: store, approvalManager: approval, engineProvider: { _ in
                ChatRoomRoleEngine(llm: llm, model: model)
            })
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentError.invalidState("测试等待流事件超时")
    }

    private func expectModel(_ message: ChatRoomMessage, _ model: ModelConfig) {
        #expect(message.provider == model.provider)
        #expect(message.modelID == model.modelID)
    }

    @Test("旧 JSONL 缺字段/null/单字段兼容，新旧混存重写不补造历史")
    func oldJSONL() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let roomID = fixture.runtime.chatroom.id
        let legacy = """
        {"id":"old","chatroomID":"\(roomID)","roleID":"A","content":"旧消息","phase":"discussion","timestamp":"2026-09-12T00:00:00Z"}
        {"id":"null","chatroomID":"\(roomID)","roleID":"B","content":"未知","phase":"discussion","timestamp":"2026-09-12T00:00:01Z","provider":null,"modelID":null}
        {"id":"one","chatroomID":"\(roomID)","roleID":"A","content":"仅模型","phase":"discussion","timestamp":"2026-09-12T00:00:02Z","modelID":"known-model"}
        """
        let url = fixture.directory.appendingPathComponent(roomID).appendingPathComponent("messages.jsonl")
        try Data((legacy + "\n").utf8).write(to: url)
        let model = ModelConfig(provider: "actual-provider", modelID: "actual-model")
        let fresh = ChatRoomMessage(chatroomID: roomID, roleID: "A", content: "新消息",
            provider: model.provider, modelID: model.modelID, phase: .discussion)
        try fixture.store.appendMessage(fresh, to: roomID)
        var loaded = try fixture.store.loadMessages(for: roomID)
        #expect(loaded.count == 4)
        #expect(loaded[0].provider == nil && loaded[0].modelID == nil)
        #expect(loaded[1].provider == nil && loaded[1].modelID == nil)
        #expect(loaded[2].provider == nil && loaded[2].modelID == "known-model")
        expectModel(loaded[3], model)
        loaded[3].termination = .cancelled
        try fixture.store.saveMessages(loaded, for: roomID)
        let reloaded = try fixture.store.loadMessages(for: roomID)
        #expect(reloaded.map(\.provider) == loaded.map(\.provider))
        #expect(reloaded.map(\.modelID) == loaded.map(\.modelID))
        #expect(reloaded[3].termination == .cancelled)
        let defaultMessage = ChatRoomMessage(chatroomID: roomID, roleID: "user", content: "", phase: .discussion)
        #expect(defaultMessage.provider == nil && defaultMessage.modelID == nil)
    }

    @Test("引擎和真实旧 provider：首帧、改配、插话、结束及 partial 落盘", arguments: [false, true], ["complete", "cancel", "fail"])
    func lifecycle(legacy: Bool, ending: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runtime = fixture.runtime
        let llm = SnapshotControlledLLM()
        let model = ModelConfig(provider: "actual-provider", modelID: "actual-model")
        let loop = fixture.loop(llm: llm, model: model, legacy: legacy)
        let task = Task { try await loop.triggerSpeaker(roleID: "A", runtime: runtime) }
        defer { task.cancel() }
        try await wait { llm.requestedModels.count == 1 && runtime.messages.count == 1 }
        expectModel(runtime.messages[0], model)
        let messageID = runtime.messages[0].id
        let timestamp = runtime.messages[0].timestamp
        llm.emit([.thinkingDelta("思考首帧")])
        try await wait { runtime.messages[0].reasoningContent == "思考首帧" }
        expectModel(runtime.messages[0], model)

        runtime.chatroom.roles[0].providerProfileID = "changed-profile"
        runtime.chatroom.roles[0].modelID = "changed-model"
        try loop.userSpeak(content: "用户插话", runtime: runtime)
        llm.emit([.textDelta("正文首帧")])
        try await wait { runtime.messages[0].content == "正文首帧" }
        expectModel(runtime.messages[0], model)
        #expect(runtime.liveSpeech?.messageID == messageID)
        #expect(runtime.messages[1].provider == nil && runtime.messages[1].modelID == nil)

        switch ending {
        case "cancel":
            // 引擎验证任务取消；旧路径通过真实 provider 抛取消，均不制造完成事件。
            if legacy { llm.fail(CancellationError()) } else { task.cancel() }
            await #expect(throws: CancellationError.self) { try await task.value }
        case "fail":
            llm.fail(AgentError.llmFailed("测试失败"))
            if legacy {
                await #expect(throws: (any Error).self) { try await task.value }
            } else {
                try await task.value
            }
        default:
            llm.emit([.textDelta("尾字"), .completed(stopReason: .stop, usage: UsageStats())], finish: true)
            try await task.value
        }

        let disk = try fixture.store.loadMessages(for: runtime.chatroom.id)
        #expect(disk.map(\.id) == runtime.messages.map(\.id))
        #expect(disk.count == 2)
        expectModel(disk[0], model)
        #expect(disk[0].roleID == "A" && disk[0].id == messageID)
        #expect(abs(disk[0].timestamp.timeIntervalSince(timestamp)) < 1)
        #expect(disk[0].reasoningContent == "思考首帧")
        #expect(disk[0].content.hasPrefix("正文首帧"))
        #expect(disk[0].termination == (ending == "complete" ? nil : ending == "cancel" ? .cancelled : .failed))
        #expect(disk[1].provider == nil && disk[1].modelID == nil)
        #expect(runtime.liveSpeech == nil && !runtime.isRunning)
        #expect(llm.requestedModels == [model])
    }

    @Test("多轮工具分段、换角色、冷恢复后同角色换模型不污染旧历史", arguments: [false, true])
    func segmentsAndRecovery(legacy: Bool) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runtime = fixture.runtime
        let llm = SnapshotControlledLLM()
        let modelA = ModelConfig(provider: "provider-A", modelID: "model-A")
        let loop = fixture.loop(llm: llm, model: modelA, legacy: legacy)
        let task = Task { try await loop.triggerSpeaker(roleID: "A", runtime: runtime) }
        defer { task.cancel() }
        try await wait { llm.requestedModels.count == 1 }
        // 未注册的测试工具只产生错误结果，不执行文件操作，也不会弹审批。
        llm.emit([.textDelta("工具前说明"),
            .toolCall(ToolCallContent(id: "snapshot-tool", name: "snapshot_noop", arguments: .object([:]))),
            .completed(stopReason: .toolUse, usage: UsageStats())], finish: true)
        try await wait { llm.requestedModels.count == 2 }
        runtime.chatroom.roles[0].modelID = "changed-mid-speech"
        llm.emit([.textDelta("最终答复"), .completed(stopReason: .stop, usage: UsageStats())], request: 1, finish: true)
        try await task.value
        let original = runtime.messages
        #expect(original.count == (legacy ? 1 : 2))
        for message in original { expectModel(message, modelA) }
        #expect(original[0].toolResults?.first?.isError == true)
        #expect(llm.requestedModels == [modelA, modelA])
        if !legacy { #expect(original[0].speechID == original[1].speechID) }

        // 每次从磁盘重新建 runtime，依次换角色 B、回到角色 A 并使用新模型。
        for roleID in ["B", "A"] {
            let restored = ChatRoomRuntime(chatroom: try fixture.store.load(id: runtime.chatroom.id))
            restored.messages = try fixture.store.loadMessages(for: restored.chatroom.id)
            let nextModel = ModelConfig(provider: "new-provider-\(roleID)", modelID: "new-model-\(roleID)")
            let nextLLM = SnapshotControlledLLM()
            let nextLoop = fixture.loop(llm: nextLLM, model: nextModel, legacy: legacy)
            let nextTask = Task { try await nextLoop.triggerSpeaker(roleID: roleID, runtime: restored) }
            defer { nextTask.cancel() }
            try await wait { nextLLM.requestedModels.count == 1 }
            nextLLM.emit([.textDelta("新发言"), .completed(stopReason: .stop, usage: UsageStats())], finish: true)
            try await nextTask.value
            expectModel(try #require(restored.messages.last), nextModel)
            #expect(restored.messages.last?.roleID == roleID)
            for (before, after) in zip(original, restored.messages) {
                #expect(before.id == after.id && before.roleID == after.roleID)
                expectModel(after, modelA)
            }
        }
        let disk = try fixture.store.loadMessages(for: runtime.chatroom.id)
        #expect(disk.suffix(2).map(\.modelID) == ["new-model-B", "new-model-A"])
        #expect(disk.suffix(2).map(\.roleID) == ["B", "A"])
    }

    private struct UnknownLegacyProvider: ChatRoomLLMProvider {
        func chat(systemPrompt: String, messages: [ChatRoomLLMMessage]) async throws -> ChatRoomLLMResponse {
            ChatRoomLLMResponse(content: "没有模型快照的旧扩展")
        }
    }
    private struct UnknownLegacyFactory: ChatRoomLLMProviderFactory {
        func createProvider(profileID: String, modelID: String, projectPath: String,
                            roleID: String, roleName: String, thinkingLevel: ThinkingLevel?) throws -> any ChatRoomLLMProvider {
            UnknownLegacyProvider()
        }
    }

    @Test("无快照的自定义旧 provider 保持兼容且不冒用角色配置")
    func unknownProvider() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = ChatRoomLoop(store: fixture.store, llmFactory: UnknownLegacyFactory(), approvalManager: fixture.approval)
        try await loop.triggerSpeaker(roleID: "A", runtime: fixture.runtime)
        let message = try #require(fixture.store.loadMessages(for: fixture.runtime.chatroom.id).first)
        #expect(message.provider == nil && message.modelID == nil)
    }
}