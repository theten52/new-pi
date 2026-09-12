import Foundation
import Testing
@testable import NewPiCore

@Suite("文件编辑记录传播与历史兼容")
struct ToolFileChangePropagationTests {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("change-propagation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func call(_ name: String = "write", id: String = "write-1", path: String = "file.txt") -> ToolCallContent {
        ToolCallContent(id: id, name: name, arguments: .object([
            "path": .string(path), "content": .string("actual\n")
        ]))
    }

    private func scripts(_ calls: [ToolCallContent]) -> [[LLMStreamEvent]] {
        [calls.map { .toolCall($0) } + [.completed(stopReason: .toolUse, usage: UsageStats())],
         [.textDelta("工具操作已完成"), .completed(stopReason: .stop, usage: UsageStats())]]
    }

    @Test("AgentLoop end、message 和最终快照携带相同记录及实测耗时")
    func agentLoop() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = await AgentLoopTestSupport.collectEvents(prompt: .user("test"),
            context: AgentContext(systemPrompt: "test", workingDirectory: root),
            config: AgentLoopConfig(model: AgentLoopTestSupport.defaultModel,
                llm: MockLLMProviderBox(scripts: scripts([call(), call(id: "unchanged")])),
                tools: [WriteTool()], toolPolicy: .allowAll))
        let ends = events.compactMap { event -> ToolResult? in
            if case let .toolExecutionEnd(_, _, result) = event { return result }; return nil
        }
        let messages = events.compactMap { event -> ToolResultMessage? in
            if case let .messageEnd(.toolResult(result)) = event { return result }; return nil
        }
        #expect(ends.count == 2 && messages.count == 2)
        #expect(ends[0].fileChanges.count == 1 && ends[1].fileChanges.isEmpty)
        for (end, message) in zip(ends, messages) {
            #expect(message.fileChanges == end.fileChanges)
            #expect(message.durationSeconds == end.durationSeconds)
            #expect((message.durationSeconds ?? -1) >= 0)
        }
        let final = try #require(events.compactMap { event -> AgentContext? in
            if case let .contextSnapshot(context) = event { return context }; return nil
        }.last)
        let persisted = final.messages.compactMap { message -> ToolResultMessage? in
            if case let .toolResult(result) = message { return result }; return nil
        }
        #expect(persisted == messages)
        #expect(try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(final.messages)) == final.messages)
    }

    @Test("实际执行失败有耗时但无编辑；拒绝、block、未知工具没有伪造耗时", arguments: ["failure", "denied", "blocked", "unknown"])
    func unsuccessful(mode: String) async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        let toolCall = call(mode == "unknown" ? "missing" : "write", path: mode == "failure" ? "directory" : "file.txt")
        let config = AgentLoopConfig(model: AgentLoopTestSupport.defaultModel,
            llm: MockLLMProviderBox(scripts: scripts([toolCall])), tools: [WriteTool()],
            toolPolicy: mode == "denied" ? .codingAgentDefault : .allowAll,
            beforeToolCall: mode == "blocked" ? { @Sendable _, _ in BeforeToolCallDecision(block: true) } : nil,
            requestToolApproval: { _ in .deny })
        let events = await AgentLoopTestSupport.collectEvents(prompt: .user("test"),
            context: AgentContext(systemPrompt: "", workingDirectory: root), config: config)
        let result = try #require(events.compactMap { event -> ToolResult? in
            if case let .toolExecutionEnd(_, _, result) = event { return result }; return nil
        }.first)
        #expect(result.isError && result.fileChanges.isEmpty)
        if mode == "failure" { #expect((result.durationSeconds ?? -1) >= 0) }
        else { #expect(result.durationSeconds == nil) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("file.txt").path))
    }

    @Test("旧 JSONL 缺字段/null 兼容，新结果重写保持不可变文件历史")
    func oldJSONL() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = #"{"toolResult":{"_0":{"toolCallID":"old","toolName":"write","content":"old output","isError":false,"timestamp":0}}}"#
        let nulls = #"{"toolResult":{"_0":{"toolCallID":"null","toolName":"write","content":"old output","isError":false,"timestamp":0,"fileChanges":null,"durationSeconds":null}}}"#
        let change = ToolFileChange.capture(path: "historical", before: "old\n", after: "new\n", beforeExists: true)
        let fresh = AgentMessage.toolResult(ToolResultMessage(toolCallID: "new", toolName: "edit", content: "ok",
            isError: false, fileChanges: [change], durationSeconds: 0.25))
        let encoded = try JSONEncoder().encode(fresh)
        let file = root.appendingPathComponent("messages.jsonl")
        try Data((old + "\n" + nulls + "\n" + String(decoding: encoded, as: UTF8.self) + "\n").utf8).write(to: file)
        let loaded = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(AgentMessage.self, from: Data($0.utf8))
        }
        for message in loaded.prefix(2) {
            guard case let .toolResult(result) = message else { Issue.record("应为工具结果"); continue }
            #expect(result.fileChanges == nil && result.durationSeconds == nil)
        }
        #expect(loaded.last == fresh)
        #expect(try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(loaded)) == loaded)
        let roomOld = try JSONDecoder().decode(ChatRoomToolResult.self,
            from: Data(#"{"toolCallID":"old","output":"ok","isError":false}"#.utf8))
        #expect(roomOld.fileChanges == nil && roomOld.durationSeconds == nil)
        #expect(ToolResult(content: "ok").fileChanges.isEmpty)
    }

    @Test("historyRepair 保留已有字段，仅给缺失工具补无元数据错误")
    func historyRepair() {
        let change = ToolFileChange.capture(path: "history", before: "a", after: "b", beforeExists: true)
        let recorded = AgentMessage.toolResult(ToolResultMessage(toolCallID: "done", toolName: "write", content: "ok",
            isError: false, fileChanges: [change], durationSeconds: 1.25))
        var messages: [AgentMessage] = [.assistant(AssistantMessage(text: "", toolCalls: [call(id: "done"), call(id: "missing")],
            provider: "mock", modelID: "mock", stopReason: .toolUse)), recorded]
        AgentMessageHistoryRepair.repairOrphanedToolCalls(in: &messages)
        #expect(messages[1] == recorded && messages.count == 3)
        if case let .toolResult(repair) = messages[2] {
            #expect(repair.isError && repair.fileChanges == nil && repair.durationSeconds == nil)
        } else { Issue.record("应补工具错误") }
    }

    @Test("Anthropic/OpenAI/Responses 不向模型发送任何文件记录元数据")
    func providerIsolation() throws {
        let change = ToolFileChange(path: "METADATA_PATH", before: "METADATA_BEFORE", after: "METADATA_AFTER",
            diff: "METADATA_PATCH", isTruncated: true, note: "METADATA_NOTE", beforeExists: true)
        let messages: [AgentMessage] = [.toolResult(ToolResultMessage(toolCallID: "result", toolName: "write",
            content: "TOOL_OUTPUT", isError: false, fileChanges: [change], durationSeconds: 123.25))]
        for payload in [AnthropicMessageEncoder.encodeMessages(messages), OpenAIMessageEncoder.encodeMessages(messages),
                        ResponsesMessageEncoder.encodeInput(messages)] {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let json = String(decoding: data, as: UTF8.self)
            #expect(json.contains("TOOL_OUTPUT"))
            for forbidden in ["METADATA_", "fileChanges", "durationSeconds", "isTruncated", "beforeExists", "123.25"] {
                #expect(!json.contains(forbidden))
            }
        }
    }
}

private struct FileChangeLegacyFactory: ChatRoomLLMProviderFactory {
    let llm: MockLLMProviderBox
    let manager: ChatRoomApprovalManager
    func createProvider(profileID: String, modelID: String, projectPath: String,
                        roleID: String, roleName: String, thinkingLevel: ThinkingLevel?) throws -> any ChatRoomLLMProvider {
        ChatRoomLLMProviderImpl(provider: llm, modelConfig: ModelConfig(provider: "mock", modelID: "mock"),
            toolExecutor: ChatRoomToolExecutor(projectPath: projectPath, approvalManager: manager))
    }
}

@Suite("聊天室文件记录全路径")
@MainActor
struct ChatRoomFileChangePropagationTests {
    private func fixture() throws -> (URL, ChatRoomStore, ChatRoomRuntime, ChatRoomApprovalManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("room-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ChatRoomStore(baseDirectory: root.appendingPathComponent("rooms"))
        let role = ChatRoomRole(id: "role", name: "Role", description: "", systemPrompt: "",
            providerProfileID: "mock", modelID: "mock")
        let room = ChatRoom(name: "测试", roles: [role], projectPath: root.path)
        try store.save(room)
        let policy = ApprovalPolicyStore(fileURL: root.appendingPathComponent("isolated-policy.json"))
        try policy.save(ApprovalPolicy(riskRules: [], toolBaseline: ["write": .medium, "edit": .medium]))
        return (root, store, ChatRoomRuntime(chatroom: room), ChatRoomApprovalManager(policyStore: policy))
    }

    @Test("真实 engine/legacy loop 的成功与无变化记录经 JSONL 冷恢复保持", arguments: [false, true])
    func roomPersistence(legacy: Bool) async throws {
        let (root, store, runtime, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.tracker.record(scope: .session, toolName: "write", fingerprint: "test", dangerLevel: .medium)
        let name = legacy ? "write_file" : "write"
        let calls = ["first", "unchanged"].map { id in ToolCallContent(id: id, name: name,
            arguments: .object(["path": .string("file.txt"), "content": .string("recorded\n")])) }
        let llm = MockLLMProviderBox(scripts: [calls.map { .toolCall($0) } + [.completed(stopReason: .toolUse, usage: UsageStats())],
            [.textDelta("工具操作已完成"), .completed(stopReason: .stop, usage: UsageStats())]])
        let loop: ChatRoomLoop
        if legacy {
            loop = ChatRoomLoop(store: store, llmFactory: FileChangeLegacyFactory(llm: llm, manager: manager), approvalManager: manager)
        } else {
            loop = ChatRoomLoop(store: store, approvalManager: manager, engineProvider: { _ in
                ChatRoomRoleEngine(llm: llm, model: ModelConfig(provider: "mock", modelID: "mock"))
            })
        }
        try await loop.triggerSpeaker(roleID: "role", runtime: runtime)
        let memory = runtime.messages.flatMap { $0.toolResults ?? [] }
        #expect(memory.count == 2)
        #expect(memory[0].fileChanges?.count == 1 && memory[1].fileChanges == [])
        #expect(memory.allSatisfy { ($0.durationSeconds ?? -1) >= 0 })
        #expect(memory[0].fileChanges?.first?.beforeExists == false)
        #expect(memory[0].fileChanges?.first?.after == "recorded\n")
        try "external\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let disk = try store.loadMessages(for: runtime.chatroom.id)
        #expect(disk.flatMap { $0.toolResults ?? [] } == memory)
        let context = ChatRoomContextBuilder.buildAgentContext(room: runtime.chatroom, history: disk)
        let encoded = try JSONSerialization.data(withJSONObject: AnthropicMessageEncoder.encodeMessages(context))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("recorded"))
    }

    @Test("legacy 实时 toolFinished 和最终结果不丢快照或耗时")
    func legacyEvents() async throws {
        let (root, _, _, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.tracker.record(scope: .session, toolName: "write", fingerprint: "test", dangerLevel: .medium)
        let call = ToolCallContent(id: "legacy", name: "write_file",
            arguments: .object(["path": .string("file.txt"), "content": .string("persisted")]))
        let llm = MockLLMProviderBox(scripts: [[.toolCall(call), .completed(stopReason: .toolUse, usage: UsageStats())],
            [.textDelta("done"), .completed(stopReason: .stop, usage: UsageStats())]])
        let provider = ChatRoomLLMProviderImpl(provider: llm, modelConfig: ModelConfig(provider: "mock", modelID: "mock"),
            toolExecutor: ChatRoomToolExecutor(projectPath: root.path, approvalManager: manager))
        var live: [ChatRoomToolResult] = []
        let response = try await provider.chatWithEvents(systemPrompt: "test", messages: [.user("test")], onEvent: {
            if case let .toolFinished(result) = $0 { live.append(result) }
        })
        #expect(live == response.toolResults && live.count == 1)
        #expect(live[0].fileChanges?.first?.after == "persisted")
        #expect((live[0].durationSeconds ?? -1) >= 0)
    }

    @Test("legacy 失败不宣称编辑，审批等待期间的变化用实际 before 捕获")
    func legacyStaleApproval() async throws {
        let (root, _, _, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try "before-preview".write(to: file, atomically: true, encoding: .utf8)
        let executor = ChatRoomToolExecutor(projectPath: root.path, approvalManager: manager)
        let call = ToolCallContent(id: "stale", name: "write_file",
            arguments: .object(["path": .string("file.txt"), "content": .string("after")]))
        let startedAt = ContinuousClock.now
        let task = Task { try await executor.execute(toolCall: call) }
        defer { task.cancel() }
        for _ in 0..<300 {
            if !manager.pendingApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let approval = try #require(manager.pendingApprovals.first)
        let preview = await ToolChangePreview.make(request: approval.request, workingDirectory: root)
        #expect(preview.fileChanges.first?.before == "before-preview")
        try await Task.sleep(for: .milliseconds(50))
        try "changed-during-approval".write(to: file, atomically: true, encoding: .utf8)
        manager.approve(id: approval.id, scope: .session)
        let result = try await task.value
        #expect(result.fileChanges?.first?.before == "changed-during-approval")
        #expect(result.fileChanges?.first?.after == "after")
        #expect((result.durationSeconds ?? -1) >= 0)
        #expect(ToolExecutionTiming.seconds(since: startedAt) - (result.durationSeconds ?? 0) >= 0.04)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        let failure = try await executor.execute(toolCall: ToolCallContent(id: "failed", name: "write_file",
            arguments: .object(["path": .string("directory"), "content": .string("bad")])))
        #expect(failure.isError && failure.fileChanges == [])
        #expect((failure.durationSeconds ?? -1) >= 0)
    }
}