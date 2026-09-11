import Foundation
import Testing
@testable import NewPiCore

// MARK: - 候选方案解析（决策 #16）

@Suite("ChatRoomCandidateParser")
struct ChatRoomCandidateParserTests {
    @Test("parses JSON block without id field")
    func jsonBlockWithoutID() {
        let text = """
        我建议以下两个方案：
        ```json
        [{"title": "方案A 简单工厂", "description": "用简单工厂模式"}]
        ```
        """
        let candidates = ChatRoomCandidateParser.parse(from: text)
        #expect(candidates?.count == 1)
        #expect(candidates?.first?.title == "方案A 简单工厂")
        #expect(candidates?.first?.id.isEmpty == false)
    }

    @Test("JSON block with explicit id keeps it")
    func jsonBlockWithID() {
        let text = """
        ```json
        [{"id": "custom-1", "title": "方案A", "description": "d"}]
        ```
        """
        let candidates = ChatRoomCandidateParser.parse(from: text)
        #expect(candidates?.first?.id == "custom-1")
    }

    @Test("falls back to plain lines with half-width and full-width colons")
    func plainLineFallback() {
        let text = "结论如下：\n方案A: 简单工厂\n方案B：策略模式\n其他内容"
        let candidates = ChatRoomCandidateParser.parse(from: text)
        #expect(candidates?.count == 2)
        #expect(candidates?[0].title == "方案A")
        #expect(candidates?[0].description == "简单工厂")
        #expect(candidates?[1].description == "策略模式")
    }

    @Test("returns nil when no candidates present")
    func noCandidates() {
        #expect(ChatRoomCandidateParser.parse(from: "普通讨论内容，没有方案") == nil)
    }

    @Test("single plain candidate line is not treated as a wrap-up")
    func singlePlainLineIgnored() {
        // 讨论中提到「方案A: …」很常见，单行不算收尾归纳
        #expect(ChatRoomCandidateParser.parse(from: "我更倾向方案A: 简单工厂") == nil)
    }
}

// MARK: - 上下文构建（署名 + 角色交替）

@Suite("ChatRoomContextBuilder")
struct ChatRoomContextBuilderTests {
    private func makeRoom(roles: [ChatRoomRole], description: String = "") -> ChatRoom {
        ChatRoom(
            name: "测试房间",
            description: description,
            roles: roles,
            projectPath: "/tmp/project"
        )
    }

    @Test("role messages carry speaker attribution and context ends with a user trigger")
    func speakerAttribution() {
        let architect = ChatRoomRole.from(preset: .architect)
        let tester = ChatRoomRole.from(preset: .tester)
        let room = makeRoom(roles: [architect, tester])
        let history = [
            ChatRoomMessage(chatroomID: room.id, roleID: "user", content: "帮我重构", phase: .discussion),
            ChatRoomMessage(chatroomID: room.id, roleID: architect.id, content: "建议简单工厂", phase: .discussion),
        ]

        let context = ChatRoomContextBuilder.messages(room: room, history: history, nextSpeaker: tester)
        #expect(context.count == 3)
        #expect(context[0].role == .user)
        #expect(context[0].content == "帮我重构")
        #expect(context[1].role == .assistant)
        #expect(context[1].content == "【架构师】建议简单工厂")
        // 末条必须是 user（Anthropic 对结尾 assistant 做 prefill 续写），并指明下一位发言人
        #expect(context[2].role == .user)
        #expect(context[2].content.contains("【测试员】"))
    }

    @Test("consecutive same-role messages are merged for API role alternation")
    func consecutiveMerge() {
        let architect = ChatRoomRole.from(preset: .architect)
        let tester = ChatRoomRole.from(preset: .tester)
        let room = makeRoom(roles: [architect, tester])
        let history = [
            ChatRoomMessage(chatroomID: room.id, roleID: "user", content: "问题", phase: .discussion),
            ChatRoomMessage(chatroomID: room.id, roleID: architect.id, content: "方案一", phase: .discussion),
            ChatRoomMessage(chatroomID: room.id, roleID: tester.id, content: "方案二", phase: .discussion),
            ChatRoomMessage(chatroomID: room.id, roleID: "user", content: "补充", phase: .discussion),
        ]

        let context = ChatRoomContextBuilder.messages(room: room, history: history)
        // 【问题】【架构师+测试员合并】【补充】——不允许连续同角色；末条已是 user，无需触发消息
        #expect(context.count == 3)
        #expect(context[1].role == .assistant)
        #expect(context[1].content.contains("【架构师】方案一"))
        #expect(context[1].content.contains("【测试员】方案二"))
        #expect(context.last?.role == .user)
    }

    @Test("assistant-first history gets a user lead message and a closing trigger")
    func assistantFirstGetsUserLead() {
        let architect = ChatRoomRole.from(preset: .architect)
        let room = makeRoom(roles: [architect], description: "重构认证模块")
        let history = [
            ChatRoomMessage(chatroomID: room.id, roleID: architect.id, content: "开始", phase: .discussion),
        ]

        let context = ChatRoomContextBuilder.messages(room: room, history: history)
        #expect(context.count == 3)
        #expect(context.first?.role == .user)
        #expect(context.first?.content.contains("重构认证模块") == true)
        #expect(context.last?.role == .user)
        #expect(context.last?.content.contains("请继续发言") == true)
    }

    @Test("empty tool-only messages get a tool summary instead of empty text")
    func toolOnlyMessageGetsSummary() {
        let architect = ChatRoomRole.from(preset: .architect)
        let room = makeRoom(roles: [architect])
        let history = [
            ChatRoomMessage(chatroomID: room.id, roleID: "user", content: "问题", phase: .discussion),
            ChatRoomMessage(
                chatroomID: room.id,
                roleID: architect.id,
                content: "",
                phase: .discussion,
                toolCalls: [ChatRoomToolCall(id: "t1", name: "read_file", arguments: "{}")]
            ),
        ]

        let context = ChatRoomContextBuilder.messages(room: room, history: history, nextSpeaker: architect)
        #expect(context.count == 3)
        #expect(context[1].content.contains("read_file"))
    }

    @Test("context uses summary checkpoint and skips system markers")
    func checkpointSummaryAndSystemSkip() {
        let architect = ChatRoomRole.from(preset: .architect)
        let room = makeRoom(roles: [architect])
        let early = ChatRoomMessage(chatroomID: room.id, roleID: "user", content: "早期问题", phase: .discussion)
        let earlyReply = ChatRoomMessage(chatroomID: room.id, roleID: architect.id, content: "早期回复", phase: .discussion)
        let marker = ChatRoomMessage(
            chatroomID: room.id,
            roleID: ChatRoomContextBuilder.systemRoleID,
            content: "🧹 已自动压缩早期对话",
            phase: .discussion
        )
        let recent = ChatRoomMessage(chatroomID: room.id, roleID: "user", content: "最近问题", phase: .discussion)

        var compacted = room
        compacted.compactionSummary = "早期对话摘要"
        compacted.compactedUpToMessageID = earlyReply.id

        let context = ChatRoomContextBuilder.messages(
            room: compacted,
            history: [early, earlyReply, marker, recent],
            nextSpeaker: architect
        )
        // 摘要置于开头并与首条 user 合并（保持角色交替）；
        // 检查点之前的消息与系统标记都不进入上下文
        #expect(context.count == 1)
        #expect(context[0].role == .user)
        #expect(context[0].content.contains("【历史摘要】早期对话摘要"))
        #expect(context[0].content.contains("最近问题"))
        #expect(!context[0].content.contains("早期问题"))
        #expect(!context[0].content.contains("已自动压缩"))
    }

    @Test("estimatedTokens counts summary and post-checkpoint messages only")
    func estimatedTokensRespectsCheckpoint() {
        let room = makeRoom(roles: [])
        let big = ChatRoomMessage(chatroomID: room.id, roleID: "user", content: String(repeating: "a", count: 400), phase: .discussion)
        let small = ChatRoomMessage(chatroomID: room.id, roleID: "user", content: "你好", phase: .discussion)
        let marker = ChatRoomMessage(chatroomID: room.id, roleID: ChatRoomContextBuilder.systemRoleID, content: "🧹 已压缩", phase: .discussion)

        let full = ChatRoomContextBuilder.estimatedTokens(room: room, history: [big, small])
        var compacted = room
        compacted.compactionSummary = "早期摘要"
        compacted.compactedUpToMessageID = big.id
        let afterCompaction = ChatRoomContextBuilder.estimatedTokens(room: compacted, history: [big, small, marker])

        // 压缩后估算显著下降
        #expect(afterCompaction < full)
        // system 标记不计入估算
        #expect(
            ChatRoomContextBuilder.estimatedTokens(room: room, history: [big, small])
                == ChatRoomContextBuilder.estimatedTokens(room: room, history: [big, small, marker])
        )
    }

    @Test("systemPrompt includes phase hint, round info, and candidates for voting")
    func systemPromptVariants() {
        let programmer = ChatRoomRole.from(preset: .programmer)

        let discussion = ChatRoomContextBuilder.systemPrompt(
            role: programmer, phase: .discussion, reviewRoundCount: 1, candidates: []
        )
        #expect(discussion.contains("讨论阶段"))
        #expect(discussion.contains("```json"))

        let executionRound1 = ChatRoomContextBuilder.systemPrompt(
            role: programmer, phase: .execution, reviewRoundCount: 1, candidates: []
        )
        #expect(executionRound1.contains("执行阶段"))
        #expect(!executionRound1.contains("轮修改"))

        let executionRound2 = ChatRoomContextBuilder.systemPrompt(
            role: programmer, phase: .execution, reviewRoundCount: 2, candidates: []
        )
        #expect(executionRound2.contains("第 2 轮修改"))

        let voting = ChatRoomContextBuilder.systemPrompt(
            role: programmer,
            phase: .voting,
            reviewRoundCount: 1,
            candidates: [CandidateOption(title: "方案A", description: "简单工厂")]
        )
        #expect(voting.contains("投票阶段"))
        #expect(voting.contains("方案A"))
    }

    @Test("execution prompt matches the selection state")
    func executionPromptSelectionState() {
        let programmer = ChatRoomRole.from(preset: .programmer)
        let options = [CandidateOption(id: "opt-1", title: "方案A", description: "简单工厂")]

        let selected = ChatRoomContextBuilder.systemPrompt(
            role: programmer, phase: .execution, reviewRoundCount: 1,
            candidates: options, selectedOptionID: "opt-1"
        )
        #expect(selected.contains("「方案A」"))

        let unselected = ChatRoomContextBuilder.systemPrompt(
            role: programmer, phase: .execution, reviewRoundCount: 1,
            candidates: options, selectedOptionID: nil
        )
        #expect(unselected.contains("选定的方案"))

        let noCandidates = ChatRoomContextBuilder.systemPrompt(
            role: programmer, phase: .execution, reviewRoundCount: 1,
            candidates: [], selectedOptionID: nil
        )
        #expect(noCandidates.contains("共识"))
    }
}

// MARK: - 阶段状态机

@Suite("ChatRoomLoop state machine")
@MainActor
struct ChatRoomLoopStateMachineTests {
    private func makeLoop() throws -> (ChatRoomLoop, ChatRoomRuntime, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: dir)
        let manager = ChatRoomApprovalManager()
        let loop = ChatRoomLoop(store: store, approvalManager: manager)
        let chatroom = ChatRoom(
            name: "状态机测试",
            roles: PresetRoleType.allCases.map { ChatRoomRole.from(preset: $0) },
            projectPath: "/tmp/project"
        )
        try store.save(chatroom)
        return (loop, ChatRoomRuntime(chatroom: chatroom), dir)
    }

    @Test("discussion proceeds directly to execution when user skips voting")
    func discussionDirectToExecution() throws {
        let (loop, runtime, _) = try makeLoop()
        try loop.advancePhase(runtime: runtime, discussionEnd: .proceedDirect)
        #expect(runtime.chatroom.currentPhase == .execution)
    }

    @Test("discussion to voting requires user choice, voting requires selection")
    func discussionToVotingFlow() throws {
        let (loop, runtime, _) = try makeLoop()
        try loop.advancePhase(runtime: runtime, discussionEnd: .startVoting)
        #expect(runtime.chatroom.currentPhase == .voting)

        // 未选方案不能进执行
        #expect(throws: ChatRoomError.self) {
            try loop.advancePhase(runtime: runtime)
        }

        try loop.userVote(optionID: "opt-1", runtime: runtime)
        #expect(runtime.chatroom.selectedOptionID == "opt-1")
        // 投票应落到对话记录
        #expect(runtime.messages.last?.content.contains("投票") == true)

        try loop.advancePhase(runtime: runtime)
        #expect(runtime.chatroom.currentPhase == .execution)
    }

    @Test("review approved completes the flow")
    func reviewApproved() throws {
        let (loop, runtime, _) = try makeLoop()
        try loop.advancePhase(runtime: runtime, discussionEnd: .proceedDirect)
        try loop.advancePhase(runtime: runtime) // execution -> review
        try loop.handleReviewResult(runtime: runtime, approved: true)
        #expect(runtime.chatroom.currentPhase == .completed)
    }

    @Test("review rejected loops back to execution with incremented round")
    func reviewRejectedNextRound() throws {
        let (loop, runtime, _) = try makeLoop()
        try loop.advancePhase(runtime: runtime, discussionEnd: .proceedDirect)
        try loop.advancePhase(runtime: runtime)
        try loop.handleReviewResult(runtime: runtime, approved: false)
        #expect(runtime.chatroom.currentPhase == .execution)
        #expect(runtime.chatroom.reviewRoundCount == 2)
        #expect(runtime.chatroom.pausedAtRoundLimit != true)
    }

    @Test("proceedDirect auto-selects the first candidate and records the decision")
    func proceedDirectAutoSelect() throws {
        let (loop, runtime, _) = try makeLoop()
        let architect = ChatRoomRole.from(preset: .architect)
        let options = [
            CandidateOption(title: "方案A", description: "简单工厂"),
            CandidateOption(title: "方案B", description: "策略模式"),
        ]
        runtime.messages = [
            ChatRoomMessage(chatroomID: runtime.chatroom.id, roleID: architect.id, content: "归纳", phase: .discussion, candidates: options)
        ]

        try loop.advancePhase(runtime: runtime, discussionEnd: .proceedDirect)
        #expect(runtime.chatroom.currentPhase == .execution)
        #expect(runtime.chatroom.selectedOptionID == options[0].id)
        // 选定结果落一条消息进历史，执行提示与状态保持一致
        #expect(runtime.messages.last?.content.contains("已确定方案") == true)
    }

    @Test("round limit pauses the flow, user can add a round or complete")
    func roundLimitPauseAndUnlock() throws {
        let (loop, runtime, _) = try makeLoop()
        try loop.advancePhase(runtime: runtime, discussionEnd: .proceedDirect)
        runtime.chatroom.reviewRoundCount = 3
        try loop.advancePhase(runtime: runtime) // execution -> review

        try loop.handleReviewResult(runtime: runtime, approved: false)
        #expect(runtime.chatroom.currentPhase == .review)
        #expect(runtime.chatroom.pausedAtRoundLimit == true)

        // 暂停状态下不能再直接 review，也不能用 advancePhase 推进
        #expect(throws: ChatRoomError.self) {
            try loop.handleReviewResult(runtime: runtime, approved: true)
        }
        #expect(throws: ChatRoomError.self) {
            try loop.advancePhase(runtime: runtime)
        }

        try loop.addRoundFromPause(runtime: runtime)
        #expect(runtime.chatroom.currentPhase == .execution)
        #expect(runtime.chatroom.reviewRoundCount == 4)
        #expect(runtime.chatroom.pausedAtRoundLimit != true)

        // 追加轮后再未通过 → 再次暂停；用户选择接受并完成
        try loop.advancePhase(runtime: runtime)
        try loop.handleReviewResult(runtime: runtime, approved: false)
        #expect(runtime.chatroom.pausedAtRoundLimit == true)
        try loop.completeFromPause(runtime: runtime)
        #expect(runtime.chatroom.currentPhase == .completed)
    }

    @Test("stopFlow completes from any phase")
    func stopFlow() throws {
        let (loop, runtime, _) = try makeLoop()
        try loop.advancePhase(runtime: runtime, discussionEnd: .startVoting)
        try loop.stopFlow(runtime: runtime)
        #expect(runtime.chatroom.currentPhase == .completed)
        #expect(runtime.chatroom.pausedAtRoundLimit != true)
    }

    @Test("invalid transitions throw")
    func invalidTransitions() async throws {
        let (loop, runtime, _) = try makeLoop()
        // discussion 必须指定结束方式（用户驱动，决策 #4）
        #expect(throws: ChatRoomError.self) {
            try loop.advancePhase(runtime: runtime)
        }
        // discussion 阶段不能直接 review
        #expect(throws: ChatRoomError.self) {
            try loop.handleReviewResult(runtime: runtime, approved: true)
        }

        // completed 阶段不能再触发发言
        try loop.stopFlow(runtime: runtime)
        let testerID = ChatRoomRole.from(preset: .tester).id
        await #expect(throws: ChatRoomError.self) {
            try await loop.triggerSpeaker(roleID: testerID, runtime: runtime)
        }
        await #expect(throws: ChatRoomError.self) {
            try await loop.triggerNextSpeaker(runtime: runtime)
        }
    }
}

// MARK: - 存储与旧格式兼容

@Suite("ChatRoomStore")
struct ChatRoomStoreTests {
    @Test("saves and loads chatroom with messages")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: dir)

        let chatroom = ChatRoom(name: "存储测试", projectPath: "/tmp/p")
        try store.save(chatroom)

        let message = ChatRoomMessage(chatroomID: chatroom.id, roleID: "user", content: "你好", phase: .discussion)
        try store.appendMessage(message, to: chatroom.id)

        let loaded = try store.load(id: chatroom.id)
        #expect(loaded.name == "存储测试")
        #expect(try store.loadMessages(for: chatroom.id).first?.content == "你好")
        #expect(try store.listAll().count == 1)

        try store.delete(id: chatroom.id)
        #expect(try store.listAll().isEmpty)
    }

    @Test("editing role config persists and hasMessages tracks conversation state")
    func editRoleConfigRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var chatroom = ChatRoom(name: "编辑测试", projectPath: "/tmp/p")
        try store.save(chatroom)
        #expect(store.hasMessages(for: chatroom.id) == false)

        // 对话开始
        try store.appendMessage(
            ChatRoomMessage(chatroomID: chatroom.id, roleID: "user", content: "开始", phase: .discussion),
            to: chatroom.id
        )
        #expect(store.hasMessages(for: chatroom.id) == true)

        // 对话开始后修改角色模型配置（对后续发言生效），保存后重新加载生效
        chatroom.roles = [
            ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m-old"),
        ]
        chatroom.roles[0].modelID = "m-new"
        try store.save(chatroom)

        let loaded = try store.load(id: chatroom.id)
        #expect(loaded.configuredRoles.count == 1)
        #expect(loaded.configuredRoles[0].modelID == "m-new")
    }

    @Test("decodes legacy chatroom.json without newer runtime fields")
    func legacyChatroomDecode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("legacy-1"),
            withIntermediateDirectories: true
        )

        let legacyJSON = """
        {
          "id": "legacy-1",
          "name": "旧格式房间",
          "description": "",
          "roles": [],
          "projectPath": "/tmp/p",
          "currentPhase": "discussion",
          "reviewRoundCount": 1,
          "votes": [],
          "createdAt": "2026-09-01T00:00:00Z",
          "updatedAt": "2026-09-01T00:00:00Z"
        }
        """
        try legacyJSON.write(
            to: dir.appendingPathComponent("legacy-1").appendingPathComponent("chatroom.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = ChatRoomStore(baseDirectory: dir)
        let loaded = try store.load(id: "legacy-1")
        #expect(loaded.name == "旧格式房间")
        #expect(loaded.currentSpeakerIndex == 0)
        #expect(loaded.pausedAtRoundLimit == nil)
    }
}

// MARK: - 审批（决策 #18）

@Suite("ChatRoomApprovalManager")
struct ChatRoomApprovalManagerTests {
    private let writeCall = ToolCallContent(
        id: "w1",
        name: "write_file",
        arguments: .object(["path": .string("a.swift"), "content": .string("let x = 1")])
    )

    @MainActor
    @Test("read-like tools are auto-approved")
    func readAutoApproved() async {
        let manager = ChatRoomApprovalManager()
        let result = await manager.requestApproval(
            toolCall: ToolCallContent(id: "r1", name: "read_file", arguments: .object(["path": .string("a.swift")])),
            roleID: "tester",
            roleName: "测试员"
        )
        if case .approved = result {} else {
            Issue.record("read_file should auto-approve")
        }
    }

    @MainActor
    @Test("write_file waits for approval and resumes on approve")
    func writeApprovalFlow() async {
        let manager = ChatRoomApprovalManager()
        let task = Task {
            await manager.requestApproval(toolCall: writeCall, roleID: "programmer", roleName: "程序员")
        }
        for _ in 0..<1000 where manager.pendingApprovals.isEmpty {
            await Task.yield()
        }
        #expect(manager.pendingApprovals.count == 1)
        #expect(manager.pendingApprovals[0].roleName == "程序员")

        manager.approve(id: manager.pendingApprovals[0].id)
        let result = await task.value
        if case .approved = result {} else {
            Issue.record("expected approved")
        }
        #expect(manager.pendingApprovals.isEmpty)
    }

    @MainActor
    @Test("cancelling the waiting task rejects the pending approval")
    func approvalCancellation() async {
        let manager = ChatRoomApprovalManager()
        let task = Task {
            await manager.requestApproval(toolCall: writeCall, roleID: "programmer", roleName: "程序员")
        }
        for _ in 0..<1000 where manager.pendingApprovals.isEmpty {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value
        if case .rejected = result {} else {
            Issue.record("expected rejected on cancel")
        }
        #expect(manager.pendingApprovals.isEmpty)
    }
}

// MARK: - Agentic loop（决策 #14）

@Suite("ChatRoomLLMProviderImpl agentic loop")
struct ChatRoomAgenticLoopTests {
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count - 1
        }
    }

    private struct MockLLMProvider: LLMProvider {
        let counter: CallCounter
        let responder: @Sendable (Int) -> [LLMStreamEvent]

        func stream(
            model: ModelConfig,
            systemPrompt: String,
            messages: [AgentMessage],
            tools: [ToolDefinition]
        ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            let index = counter.next()
            return AsyncThrowingStream { continuation in
                for event in responder(index) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private final class SpeechEventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ChatRoomSpeechEvent] = []
        func append(_ event: ChatRoomSpeechEvent) {
            lock.lock()
            defer { lock.unlock() }
            items.append(event)
        }
        var snapshot: [ChatRoomSpeechEvent] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    @Test("tool results are fed back and tool usage is recorded in the response")
    func agenticLoopRecordsToolUsage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello chatroom".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let manager = ChatRoomApprovalManager()
        let executor = ChatRoomToolExecutor(
            projectPath: dir.path,
            approvalManager: manager,
            roleID: "programmer",
            roleName: "程序员"
        )

        let counter = CallCounter()
        let mock = MockLLMProvider(counter: counter) { index in
            if index == 0 {
                return [
                    .toolCall(ToolCallContent(
                        id: "call-1",
                        name: "read_file",
                        arguments: .object(["path": .string("hello.txt")])
                    ))
                ]
            }
            return [
                .textDelta("文件内容已确认"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ]
        }

        let impl = ChatRoomLLMProviderImpl(
            provider: mock,
            modelConfig: ModelConfig(provider: "mock", modelID: "test-model"),
            toolExecutor: executor
        )

        let response = try await impl.chat(
            systemPrompt: "测试",
            messages: [ChatRoomLLMMessage.user("读取 hello.txt")]
        )

        #expect(response.content == "文件内容已确认")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].id == "call-1")
        #expect(response.toolCalls[0].name == "read_file")
        #expect(response.toolResults.count == 1)
        #expect(response.toolResults[0].toolCallID == "call-1")
        #expect(response.toolResults[0].output.contains("hello chatroom"))
        #expect(response.toolResults[0].isError == false)
    }

    @Test("max_tokens truncation is marked in the response content")
    func maxTokensTruncationMarker() async throws {
        let counter = CallCounter()
        let mock = MockLLMProvider(counter: counter) { _ in
            [
                .textDelta("写到一半的内容"),
                .completed(stopReason: .length, usage: UsageStats()),
            ]
        }

        let impl = ChatRoomLLMProviderImpl(
            provider: mock,
            modelConfig: ModelConfig(provider: "mock", modelID: "test-model"),
            toolExecutor: ChatRoomToolExecutor(
                projectPath: FileManager.default.temporaryDirectory.path,
                approvalManager: ChatRoomApprovalManager()
            )
        )

        let response = try await impl.chat(
            systemPrompt: "测试",
            messages: [ChatRoomLLMMessage.user("写个长文件")]
        )
        #expect(response.content.contains("写到一半的内容"))
        #expect(response.content.contains("[输出被截断"))
    }

    @Test("chatWithEvents streams text deltas and tool events in order")
    func chatWithEventsSequence() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello chatroom".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let executor = ChatRoomToolExecutor(
            projectPath: dir.path,
            approvalManager: ChatRoomApprovalManager()
        )

        let counter = CallCounter()
        let mock = MockLLMProvider(counter: counter) { index in
            if index == 0 {
                return [
                    .textDelta("开始 "),
                    .toolCall(ToolCallContent(
                        id: "call-1",
                        name: "read_file",
                        arguments: .object(["path": .string("hello.txt")])
                    )),
                ]
            }
            return [
                .textDelta("最终回复"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ]
        }

        let impl = ChatRoomLLMProviderImpl(
            provider: mock,
            modelConfig: ModelConfig(provider: "mock", modelID: "test-model"),
            toolExecutor: executor
        )

        let collector = SpeechEventCollector()
        let response = try await impl.chatWithEvents(
            systemPrompt: "测试",
            messages: [ChatRoomLLMMessage.user("读取 hello.txt")],
            onEvent: { event in collector.append(event) }
        )

        #expect(response.content == "最终回复")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolResults.count == 1)

        // 事件顺序：文本 → 工具开始 → 工具完成 → 下一轮文本
        let events = collector.snapshot
        #expect(events.count == 4)
        guard case .textDelta(let firstText)? = events.first else {
            Issue.record("first event should be textDelta")
            return
        }
        #expect(firstText.contains("开始"))
        guard case .toolStarted(let startedCall)? = events.dropFirst().first else {
            Issue.record("second event should be toolStarted")
            return
        }
        #expect(startedCall.name == "read_file")
        guard case .toolFinished(let finishedResult)? = events.dropFirst(2).first else {
            Issue.record("third event should be toolFinished")
            return
        }
        #expect(finishedResult.output.contains("hello chatroom"))
        guard case .textDelta(let lastText)? = events.last else {
            Issue.record("last event should be textDelta")
            return
        }
        #expect(lastText == "最终回复")
    }

    @Test("thinking deltas stream as events and accumulate into reasoningContent")
    func thinkingStreamingAndAccumulation() async throws {
        let executor = ChatRoomToolExecutor(
            projectPath: FileManager.default.temporaryDirectory.path,
            approvalManager: ChatRoomApprovalManager()
        )

        let counter = CallCounter()
        let mock = MockLLMProvider(counter: counter) { _ in
            [
                .thinkingDelta("思考第一段"),
                .thinkingDelta("思考第二段"),
                .textDelta("正文"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ]
        }

        let impl = ChatRoomLLMProviderImpl(
            provider: mock,
            modelConfig: ModelConfig(provider: "mock", modelID: "test-model"),
            toolExecutor: executor
        )

        let collector = SpeechEventCollector()
        let response = try await impl.chatWithEvents(
            systemPrompt: "测试",
            messages: [ChatRoomLLMMessage.user("问题")],
            onEvent: { event in collector.append(event) }
        )

        // 思考增量按序推送
        let thinkingEvents = collector.snapshot.compactMap { event -> String? in
            if case .thinkingDelta(let text) = event { return text }
            return nil
        }
        #expect(thinkingEvents == ["思考第一段", "思考第二段"])
        // 思考累积进响应
        #expect(response.reasoningContent == "思考第一段思考第二段")
        #expect(response.content == "正文")
    }

    @Test("events flow through existential dispatch (protocol requirement regression)")
    func existentialDispatchRoutesEvents() async throws {
        // 回归（2026-09-05）：chatWithEvents 曾只定义在 extension 里，app 通过
        // `any ChatRoomLLMProvider` 存在容器调用时静态派发到默认实现、onEvent
        // 被丢弃（实时显示不生效的根因）。必须通过存在容器验证。
        let executor = ChatRoomToolExecutor(
            projectPath: FileManager.default.temporaryDirectory.path,
            approvalManager: ChatRoomApprovalManager()
        )

        let counter = CallCounter()
        let mock = MockLLMProvider(counter: counter) { _ in
            [
                .textDelta("存在容器事件"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ]
        }

        let provider: any ChatRoomLLMProvider = ChatRoomLLMProviderImpl(
            provider: mock,
            modelConfig: ModelConfig(provider: "mock", modelID: "test-model"),
            toolExecutor: executor
        )

        let collector = SpeechEventCollector()
        let response = try await provider.chatWithEvents(
            systemPrompt: "测试",
            messages: [ChatRoomLLMMessage.user("问题")],
            onEvent: { event in collector.append(event) }
        )

        #expect(response.content == "存在容器事件")
        #expect(!collector.snapshot.isEmpty)
        guard case .textDelta(let text)? = collector.snapshot.first else {
            Issue.record("first event should be textDelta")
            return
        }
        #expect(text == "存在容器事件")
    }

    @Test("rejected write does not modify the file and error is returned to the model")
    func rejectedWriteReturnsErrorResult() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manager = ChatRoomApprovalManager()
        let executor = ChatRoomToolExecutor(
            projectPath: dir.path,
            approvalManager: manager,
            roleID: "programmer",
            roleName: "程序员"
        )

        let counter = CallCounter()
        let mock = MockLLMProvider(counter: counter) { index in
            if index == 0 {
                return [
                    .toolCall(ToolCallContent(
                        id: "call-w",
                        name: "write_file",
                        arguments: .object(["path": .string("new.txt"), "content": .string("data")])
                    ))
                ]
            }
            return [.textDelta("收到拒绝"), .completed(stopReason: .stop, usage: UsageStats())]
        }

        let impl = ChatRoomLLMProviderImpl(
            provider: mock,
            modelConfig: ModelConfig(provider: "mock", modelID: "test-model"),
            toolExecutor: executor
        )

        // 在后台拒绝审批请求
        let rejectTask = Task { @MainActor in
            for _ in 0..<1000 where manager.pendingApprovals.isEmpty {
                await Task.yield()
            }
            manager.reject(id: manager.pendingApprovals.first?.id ?? "")
        }

        let response = try await impl.chat(
            systemPrompt: "测试",
            messages: [ChatRoomLLMMessage.user("写入文件")]
        )
        _ = await rejectTask.value

        #expect(response.toolResults.count == 1)
        #expect(response.toolResults[0].isError == true)
        #expect(response.toolResults[0].output.contains("拒绝"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path))
    }
}

// MARK: - 聊天室模板

@Suite("ChatRoomTemplateStore")
struct ChatRoomTemplateStoreTests {
    @Test("seeds builtin templates on first run")
    func seedsOnFirstRun() throws {
        let store = ChatRoomTemplateStore(baseDirectory: tempDirectory())
        defer { try? FileManager.default.removeItem(at: store.baseDirectoryForTesting) }

        let templates = try store.listAll()
        #expect(templates.count == 3)
        #expect(templates.contains { $0.name == "默认四人组" && $0.roles.count == 4 })
        #expect(templates.contains { $0.name == "两人极速组" && $0.roles.count == 2 })
        #expect(templates.contains { $0.name == "评审组" && $0.roles.count == 2 })
        // seed 等价原预设流程：不预绑 provider/model
        #expect(templates.allSatisfy { template in
            template.roles.allSatisfy { $0.providerProfileID == nil && $0.modelID == nil }
        })
    }

    @Test("does not re-seed after user deletes all templates")
    func noReseedAfterDeleteAll() throws {
        let store = ChatRoomTemplateStore(baseDirectory: tempDirectory())
        defer { try? FileManager.default.removeItem(at: store.baseDirectoryForTesting) }

        _ = try store.listAll() // 触发 seed
        for template in try store.listAll() {
            try store.delete(id: template.id)
        }
        #expect(try store.listAll().isEmpty)
    }

    @Test("save and load round trip")
    func roundTrip() throws {
        let store = ChatRoomTemplateStore(baseDirectory: tempDirectory())
        defer { try? FileManager.default.removeItem(at: store.baseDirectoryForTesting) }

        var template = ChatRoomTemplate(
            name: "自定义组",
            description: "测试模板",
            roles: [ChatRoomRole(name: "评审员", description: "看代码", systemPrompt: "提示词", providerProfileID: "p1", modelID: "m1")]
        )
        try store.save(template)
        // 已有目录（save 时创建），不应触发 seed
        template.name = "改名组"
        template.roles[0].modelID = "m2"
        try store.save(template)

        let loaded = try store.listAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "改名组")
        #expect(loaded[0].roles[0].modelID == "m2")

        try store.delete(id: template.id)
        #expect(try store.listAll().isEmpty)
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-templates-\(UUID().uuidString)", isDirectory: true)
    }
}

@Suite("ChatRoomTemplate 套用")
struct ChatRoomTemplateApplyTests {
    @Test("invalid provider or model bindings are downgraded and reported")
    func invalidBindingsDowngraded() {
        let bound = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "ok", modelID: "m1")
        let providerGone = ChatRoomRole(name: "测试员", description: "", systemPrompt: "x", providerProfileID: "gone", modelID: "m2")
        let modelGone = ChatRoomRole(name: "评审员", description: "", systemPrompt: "x", providerProfileID: "ok", modelID: "removed-model")
        let unboundModel = ChatRoomRole(name: "自由人", description: "", systemPrompt: "x", providerProfileID: "ok")
        let template = ChatRoomTemplate(name: "t", roles: [bound, providerGone, modelGone, unboundModel])

        let result = template.resolvedRoles(profileModels: ["ok": ["m1", "m2"]])

        // 有效绑定原样保留
        #expect(result.roles[0].providerProfileID == "ok")
        #expect(result.roles[0].modelID == "m1")
        // provider 已删除 → 整体降级
        #expect(result.roles[1].providerProfileID == nil)
        #expect(result.roles[1].modelID == nil)
        // model 已从 provider 模型列表移除 → 整体降级
        #expect(result.roles[2].providerProfileID == nil)
        #expect(result.roles[2].modelID == nil)
        // provider 有效且未绑 model → 保留（等用户补选）
        #expect(result.roles[3].providerProfileID == "ok")
        #expect(result.roles[3].modelID == nil)
        #expect(result.roles[3].isConfigured == false)

        // 失效按 roleID 报告（provider 失效与 model 失效都算）
        #expect(result.invalidatedRoleIDs == [providerGone.id, modelGone.id])
    }
}

// MARK: - 实时发言（流式事件上屏）

@Suite("ChatRoomLoop 实时发言")
@MainActor
struct ChatRoomLiveSpeechTests {
    /// 覆写 chatWithEvents：推送实时事件并返回最终响应
    private struct StreamingMockProvider: ChatRoomLLMProvider {
        func chat(systemPrompt: String, messages: [ChatRoomLLMMessage]) async throws -> ChatRoomLLMResponse {
            try await chatWithEvents(systemPrompt: systemPrompt, messages: messages, onEvent: nil)
        }

        func chatWithEvents(
            systemPrompt: String,
            messages: [ChatRoomLLMMessage],
            onEvent: (@MainActor @Sendable (ChatRoomSpeechEvent) -> Void)?
        ) async throws -> ChatRoomLLMResponse {
            await onEvent?(.textDelta("流式"))
            await onEvent?(.toolStarted(ChatRoomToolCall(id: "t1", name: "read_file", arguments: "{}")))
            await onEvent?(.toolFinished(ChatRoomToolResult(toolCallID: "t1", output: "内容", isError: false)))
            return ChatRoomLLMResponse(
                content: "最终发言",
                toolCalls: [ChatRoomToolCall(id: "t1", name: "read_file", arguments: "{}")],
                toolResults: [ChatRoomToolResult(toolCallID: "t1", output: "内容", isError: false)]
            )
        }
    }

    private struct FailingProvider: ChatRoomLLMProvider {
        struct Boom: Error {}
        func chat(systemPrompt: String, messages: [ChatRoomLLMMessage]) async throws -> ChatRoomLLMResponse {
            throw Boom()
        }
    }

    private func makeLoop(
        provider: some ChatRoomLLMProvider
    ) throws -> (ChatRoomLoop, ChatRoomRuntime, ChatRoomStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-live-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: dir)
        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "实时发言测试", roles: [role], projectPath: "/tmp/p")
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)
        let loop = ChatRoomLoop(store: store, llmFactory: MockProviderFactory(provider: provider))
        return (loop, runtime, store, dir)
    }

    private struct MockProviderFactory: ChatRoomLLMProviderFactory {
        let provider: ChatRoomLLMProvider
        func createProvider(
            profileID: String,
            modelID: String,
            projectPath: String,
            roleID: String,
            roleName: String,
            thinkingLevel: ThinkingLevel?
        ) throws -> ChatRoomLLMProvider {
            provider
        }
    }

    @Test("live speech finalizes the provisional message and persists once")
    func liveSpeechFinalizes() async throws {
        let (loop, runtime, store, dir) = try makeLoop(provider: StreamingMockProvider())
        defer { try? FileManager.default.removeItem(at: dir) }

        try await loop.triggerNextSpeaker(runtime: runtime)

        // 临时消息被定型为最终发言（内容以最终响应覆盖实时累积）
        #expect(runtime.messages.count == 1)
        #expect(runtime.messages.last?.content == "最终发言")
        #expect(runtime.messages.last?.toolCalls?.count == 1)
        #expect(runtime.messages.last?.toolResults?.count == 1)
        // 只有定型后的消息落盘（实时改写过程不写 messages.jsonl）
        let persisted = try store.loadMessages(for: runtime.chatroom.id)
        #expect(persisted.count == 1)
        #expect(persisted.last?.content == "最终发言")
    }

    @Test("failure before output removes the empty provisional message")
    func failedSpeechCleansUp() async throws {
        let (loop, runtime, store, dir) = try makeLoop(provider: FailingProvider())
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: (Error).self) {
            try await loop.triggerNextSpeaker(runtime: runtime)
        }

        // 临时消息已移除，历史与落盘都不留残骸
        #expect(runtime.messages.isEmpty)
        #expect(try store.loadMessages(for: runtime.chatroom.id).isEmpty)
    }
}

// MARK: - 自动压缩（决策 #7，2026-09-05 调整）

@Suite("ChatRoomLoop 自动压缩")
@MainActor
struct ChatRoomCompactionTests {
    private final class ResponseQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String]
        init(_ items: [String]) { self.items = items }
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            return items.isEmpty ? "（无回复）" : items.removeFirst()
        }
    }

    private struct MockChatRoomProvider: ChatRoomLLMProvider {
        let queue: ResponseQueue
        func chat(systemPrompt: String, messages: [ChatRoomLLMMessage]) async throws -> ChatRoomLLMResponse {
            ChatRoomLLMResponse(content: queue.next())
        }
    }

    private struct MockFactory: ChatRoomLLMProviderFactory {
        let queue: ResponseQueue
        func createProvider(
            profileID: String,
            modelID: String,
            projectPath: String,
            roleID: String,
            roleName: String,
            thinkingLevel: ThinkingLevel?
        ) throws -> ChatRoomLLMProvider {
            MockChatRoomProvider(queue: queue)
        }
    }

    @Test("compacts history and records checkpoint when budget threshold is reached")
    func compactsWhenOverBudget() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-compaction-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "压缩测试", roles: [role], projectPath: "/tmp/p")
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)
        for index in 0..<12 {
            runtime.messages.append(
                ChatRoomMessage(chatroomID: chatroom.id, roleID: "user", content: "历史消息 \(index)", phase: .discussion)
            )
        }

        // 第一次 chat 调用 = 压缩摘要，第二次 = 正式发言
        let queue = ResponseQueue(["这是压缩摘要", "最终发言"])
        let loop = ChatRoomLoop(
            store: store,
            llmFactory: MockFactory(queue: queue),
            contextBudgetTokens: { _ in 50 } // 极小预算，必然触发
        )

        try await loop.triggerNextSpeaker(runtime: runtime)

        #expect(runtime.chatroom.compactionSummary == "这是压缩摘要")
        // 检查点落在被摘要的最后一条消息上（12 条、保留最近 8 条 → 前 4 条被摘要）
        #expect(runtime.messages.first { $0.id == runtime.chatroom.compactedUpToMessageID }?.content == "历史消息 3")
        // 展示标记（roleID=system）落盘且不进入上下文
        #expect(runtime.messages.contains { $0.roleID == "system" && $0.content.contains("自动压缩") })
        #expect(runtime.messages.last?.content == "最终发言")

        let reloaded = try store.load(id: chatroom.id)
        #expect(reloaded.compactionSummary == "这是压缩摘要")
    }

    @Test("compaction is skipped when a budget is not provided")
    func noBudgetNoCompaction() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-compaction-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "无预算", roles: [role], projectPath: "/tmp/p")
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)
        for index in 0..<12 {
            runtime.messages.append(
                ChatRoomMessage(chatroomID: chatroom.id, roleID: "user", content: "历史消息 \(index)", phase: .discussion)
            )
        }

        let queue = ResponseQueue(["最终发言"])
        let loop = ChatRoomLoop(store: store, llmFactory: MockFactory(queue: queue))

        try await loop.triggerNextSpeaker(runtime: runtime)

        #expect(runtime.chatroom.compactionSummary == nil)
        #expect(!runtime.messages.contains { $0.roleID == "system" })
        #expect(runtime.messages.last?.content == "最终发言")
    }
}

// MARK: - 引擎路径（Phase B：AgentLoop 直驱）

@Suite("ChatRoomLoop 引擎路径")
@MainActor
struct ChatRoomEngineSpeechTests {
    private final class StreamCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var seenMessageCounts: [Int] = []
        func next(messageCount: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            seenMessageCounts.append(messageCount)
            let index = self.count
            self.count += 1
            return index
        }
        var history: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return seenMessageCounts
        }
    }

    /// LLMProvider 级 mock（引擎路径的真实输入形态）
    private struct EngineMockLLMProvider: LLMProvider {
        let responder: @Sendable (Int, [AgentMessage]) -> [LLMStreamEvent]

        func stream(
            model: ModelConfig,
            systemPrompt: String,
            messages: [AgentMessage],
            tools: [ToolDefinition]
        ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in responder(messages.count, messages) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    private struct ThrowingLLMProvider: LLMProvider {
        func stream(
            model: ModelConfig,
            systemPrompt: String,
            messages: [AgentMessage],
            tools: [ToolDefinition]
        ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: LLMErrorMock())
            }
        }
    }

    private struct LLMErrorMock: Error {}

    private func makeEngineLoop(
        llm: any LLMProvider,
        store: ChatRoomStore
    ) -> ChatRoomLoop {
        ChatRoomLoop(
            store: store,
            llmFactory: nil,
            engineProvider: { _ in
                ChatRoomRoleEngine(llm: llm, model: ModelConfig(provider: "mock", modelID: "engine-model"))
            }
        )
    }

    @Test("engine speak streams text into provisional and finalizes")
    func engineStreamsText() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-engine-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "引擎测试", roles: [role], projectPath: "/tmp/p")
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)

        let llm = EngineMockLLMProvider { callIndex, _ in
            [
                .textDelta("引擎"),
                .textDelta("正文"),
                .completed(stopReason: .stop, usage: UsageStats(inputTokens: 10, outputTokens: 5)),
            ]
        }
        let loop = makeEngineLoop(llm: llm, store: store)

        try await loop.triggerNextSpeaker(runtime: runtime)

        #expect(runtime.messages.count == 1)
        #expect(runtime.messages.last?.content == "引擎正文")
        // 用量累计（messageEnd(.assistant)）
        #expect(runtime.usage.outputTokens == 5)
        // 落盘一次
        let persisted = try store.loadMessages(for: chatroom.id)
        #expect(persisted.count == 1)
        #expect(persisted.last?.content == "引擎正文")
    }

    @Test("engine tool events map to tool cards with results")
    func engineToolCards() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "引擎读到的内容".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "引擎工具测试", roles: [role], projectPath: dir.path)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-engine-store-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: storeDir)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)

        let llm = EngineMockLLMProvider { messageCount, _ in
            if messageCount <= 1 {
                return [
                    .toolCall(ToolCallContent(
                        id: "call-1",
                        name: "read",
                        arguments: .object(["path": .string("hello.txt")])
                    ))
                ]
            }
            return [
                .textDelta("读完了"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ]
        }
        let loop = makeEngineLoop(llm: llm, store: store)

        try await loop.triggerNextSpeaker(runtime: runtime)

        // 两个迭代分段：段1 = read 工具（BuiltInTools 真实执行，读自动过），段2 = 正文
        #expect(runtime.messages.count == 2)
        let toolSegment = runtime.messages[0]
        let textSegment = runtime.messages[1]
        #expect(toolSegment.speechID != nil)
        #expect(toolSegment.speechID == textSegment.speechID)
        #expect(toolSegment.toolCalls?.first?.name == "read")
        #expect(toolSegment.toolResults?.first?.output.contains("引擎读到的内容") == true)
        #expect(toolSegment.toolResults?.first?.isError == false)
        #expect(textSegment.content == "读完了")
        #expect(textSegment.toolCalls?.isEmpty != false)
    }

    @Test("steering enqueued mid-run reaches the model and lands in history")
    func steeringReachesModel() async throws {
        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "steering 测试", roles: [role], projectPath: "/tmp/p")
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-steer-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: storeDir)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)

        // 第 0 次调用先发起一次工具调用（触发 steering 轮询），
        // 第 1 次调用回显收到的消息数（应包含插话）
        let callIndex = StreamCounter()
        let llm = EngineMockLLMProvider { _, messages in
            if callIndex.next(messageCount: messages.count) == 0 {
                return [
                    .toolCall(ToolCallContent(
                        id: "call-s",
                        name: "read",
                        arguments: .object(["path": .string("whatever.txt")])
                    ))
                ]
            }
            let labels = messages.map { message -> String in
                switch message {
                case .user(let u): return "user:\(u.content.prefix(12))"
                case .assistant(let a): return "assistant:\(a.text.prefix(12))"
                case .toolResult(let t): return "tool:\(t.content.prefix(12))"
                case .compactionSummary: return "summary"
                }
            }.joined(separator: ",")
            return [.textDelta("共收到 \(messages.count) 条[\(labels)]"), .completed(stopReason: .stop, usage: UsageStats())]
        }
        let loop = makeEngineLoop(llm: llm, store: store)

        // 预注入 steering：等价于发言中 userSpeak 的双写（队列 + 共享历史）
        loop.enqueueSteering(.user(UserMessage(content: "插话：优先看主文件")))
        runtime.messages.append(ChatRoomMessage(
            chatroomID: chatroom.id,
            roleID: "user",
            content: "插话：优先看主文件",
            phase: .discussion
        ))

        try await loop.triggerNextSpeaker(runtime: runtime)

        // 插话落在共享历史
        #expect(runtime.messages.contains { $0.roleID == "user" && $0.content.contains("插话") })
        // 模型在工具批次后的下一轮看到了插话：
        // prompt(trigger) + assistant(工具调用) + toolResult + steering = 4 条
        let finalContent = runtime.messages.last?.content ?? ""
        // 模型在工具批次后的下一轮看到了插话：
        // [user(插话+trigger 合并), assistant(toolcall), toolResult, steering] = 4 条
        #expect(finalContent.contains("共收到 4 条"), "actual content: \(finalContent)")
    }

    @Test("trailing user history merges with the trigger (no consecutive user roles)")
    func trailingUserMergesTrigger() async throws {
        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "合并触发测试", roles: [role], projectPath: "/tmp/p")
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-merge-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: storeDir)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)

        // 共享历史以 user 结尾（插话后推进的常见形态）
        runtime.messages.append(ChatRoomMessage(
            chatroomID: chatroom.id,
            roleID: "user",
            content: "插话：用 SwiftUI 实现",
            phase: .discussion
        ))

        final class Capture: @unchecked Sendable {
            var labels: [String] = []
        }
        let capture = Capture()
        let llm = EngineMockLLMProvider { _, messages in
            capture.labels = messages.map { message -> String in
                switch message {
                case .user(let u): return "user:\(u.content)"
                case .assistant(let a): return "assistant:\(a.text)"
                case .toolResult: return "tool"
                case .compactionSummary: return "summary"
                }
            }
            return [.textDelta("收到"), .completed(stopReason: .stop, usage: UsageStats())]
        }
        let loop = makeEngineLoop(llm: llm, store: store)

        try await loop.triggerNextSpeaker(runtime: runtime)

        // 触发消息并入末条 user：单条消息同时含插话与身份指令，且无连续 user
        #expect(capture.labels.count == 1)
        #expect(capture.labels[0].contains("插话：用 SwiftUI 实现"))
        #expect(capture.labels[0].contains("请以【程序员】的身份发言"))
    }

    @Test("LLM failure is surfaced as an error note on the finalized message")
    func engineFailureNote() async throws {
        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "失败测试", roles: [role], projectPath: "/tmp/p")
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-fail-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: storeDir)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)

        let loop = makeEngineLoop(llm: ThrowingLLMProvider(), store: store)

        try await loop.triggerNextSpeaker(runtime: runtime)

        // AgentLoop 把 LLM 异常转为 .error 事件 → 发言以失败标记定型（不抛出、不丢工具记录）
        #expect(runtime.messages.last?.content.contains("发言失败") == true)
    }

    @Test("agentic iterations become chronological segments sharing one speechID")
    func chronologicalSegments() async throws {
        let role = ChatRoomRole(name: "程序员", description: "", systemPrompt: "x", providerProfileID: "p1", modelID: "m1")
        let chatroom = ChatRoom(name: "分段测试", roles: [role], projectPath: "/tmp/p")
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-seg-\(UUID().uuidString)", isDirectory: true)
        let store = ChatRoomStore(baseDirectory: storeDir)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        try store.save(chatroom)
        let runtime = ChatRoomRuntime(chatroom: chatroom)

        let llm = EngineMockLLMProvider { messageCount, _ in
            if messageCount <= 1 {
                // 迭代 1：中间解说 + 工具调用
                return [
                    .thinkingDelta("第一段思考"),
                    .textDelta("先看一下文件。"),
                    .toolCall(ToolCallContent(
                        id: "call-1",
                        name: "read",
                        arguments: .object(["path": .string("a.txt")])
                    )),
                ]
            }
            // 迭代 2：新思考 + 最终答复
            return [
                .thinkingDelta("第二段思考"),
                .textDelta("最终答复"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ]
        }
        let loop = makeEngineLoop(llm: llm, store: store)

        try await loop.triggerNextSpeaker(runtime: runtime)

        // 两个分段，同一 speechID，按时间顺序排列
        #expect(runtime.messages.count == 2)
        let seg1 = runtime.messages[0]
        let seg2 = runtime.messages[1]
        #expect(seg1.speechID != nil && seg1.speechID == seg2.speechID)

        // 段1：思考 + 中间解说 + 工具；段2：思考 + 最终答复（无工具）
        #expect(seg1.reasoningContent == "第一段思考")
        #expect(seg1.content == "先看一下文件。")
        #expect(seg1.toolCalls?.count == 1)
        #expect(seg2.reasoningContent == "第二段思考")
        #expect(seg2.content == "最终答复")
        #expect(seg2.toolCalls == nil || seg2.toolCalls?.isEmpty == true)

        // 落盘顺序与展示顺序一致
        let persisted = try store.loadMessages(for: chatroom.id)
        #expect(persisted.map(\.content) == ["先看一下文件。", "最终答复"])
    }

    @Test("approval bridge converts decisions and resumes the loop wait")
    func approvalBridge() async {
        let manager = ChatRoomApprovalManager()
        let request = ToolApprovalRequest(
            id: "req-1",
            toolName: "write",
            arguments: .object(["path": .string("a.swift")]),
            summary: "写入文件: a.swift"
        )

        let task = Task {
            await manager.approvalDecision(for: request, roleID: "programmer", roleName: "程序员")
        }
        for _ in 0 ..< 1000 where manager.pendingApprovals.isEmpty {
            await Task.yield()
        }
        #expect(manager.pendingApprovals.count == 1)

        manager.approve(id: manager.pendingApprovals[0].id)
        let decision = await task.value
        #expect(decision.approved == true)
        #expect(manager.pendingApprovals.isEmpty)
    }
}

// MARK: - 路径安全（validatePath）

@Suite("ChatRoomPathValidator")
struct ChatRoomPathValidatorTests {
    @Test("rejects absolute paths and traversal")
    func rejectsAbsoluteAndTraversal() {
        #expect(ChatRoomPathValidator.validate("/etc/passwd", projectPath: "/tmp/project") == nil)
        #expect(ChatRoomPathValidator.validate("../../etc/passwd", projectPath: "/tmp/project") == nil)
        #expect(ChatRoomPathValidator.validate("src/../../etc", projectPath: "/tmp/project") == nil)
    }

    @Test("allows valid relative paths")
    func allowsRelativePaths() throws {
        let url = ChatRoomPathValidator.validate("src/Main.swift", projectPath: "/tmp/project")
        #expect(url?.path == "/tmp/project/src/Main.swift")
    }

    @Test("rejects symlink escaping the project root")
    func rejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-path-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: outside
        )

        #expect(ChatRoomPathValidator.validate("link/secret.txt", projectPath: root.path) == nil)
        #expect(ChatRoomPathValidator.validate("normal.txt", projectPath: root.path) != nil)
    }

    @Test("handles projectPath with trailing slash")
    func trailingSlashProjectPath() {
        let url = ChatRoomPathValidator.validate("a.txt", projectPath: "/tmp/project/")
        #expect(url?.path == "/tmp/project/a.txt")
    }
}

// MARK: - 工具执行器行为

@Suite("ChatRoomToolExecutor behavior")
struct ChatRoomToolExecutorBehaviorTests {
    @Test("search_files prunes .git and dependency directories")
    func searchPrunesVCSDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "marker-token".write(to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "marker-token".write(to: root.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        try "marker-token here".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)

        let executor = ChatRoomToolExecutor(
            projectPath: root.path,
            approvalManager: ChatRoomApprovalManager()
        )
        let result = try await executor.execute(toolCall: ToolCallContent(
            id: "s1",
            name: "search_files",
            arguments: .object(["query": .string("marker-token")])
        ))

        #expect(result.isError == false)
        #expect(result.output.contains("src/main.swift"))
        #expect(!result.output.contains("/.git/"))
        #expect(!result.output.contains("node_modules"))
    }

    @Test("read_file truncation respects UTF-8 character boundaries")
    func readFileUTF8Boundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatroom-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 前 limit-1 字节是 ASCII，最后的「中」跨过截断点被切掉一半
        let content = String(repeating: "x", count: ChatRoomTools.readFileSizeLimit - 1) + "中"
        try content.write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let executor = ChatRoomToolExecutor(
            projectPath: root.path,
            approvalManager: ChatRoomApprovalManager()
        )
        let result = try await executor.execute(toolCall: ToolCallContent(
            id: "r1",
            name: "read_file",
            arguments: .object(["path": .string("big.txt")])
        ))

        #expect(result.isError == false)
        #expect(result.output.contains("已截断"))
        #expect(!result.output.contains("\u{FFFD}"))
    }
}
