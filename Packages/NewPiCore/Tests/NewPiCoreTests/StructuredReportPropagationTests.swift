import Foundation
import Testing
@testable import NewPiCore

@Suite("结构化报告传播与兼容")
struct StructuredReportPropagationTests {
    @Test("普通 AgentLoop 事件、消息、快照及 JSONL 冷恢复传递报告")
    func agentLoop() async throws {
        let root = try StructuredReportFixtures.project()
        defer { try? FileManager.default.removeItem(at: root) }
        try StructuredReportFixtures.xml.write(to: root.appendingPathComponent("report.xml"), atomically: true, encoding: .utf8)
        let llm = MockLLMProviderBox(scripts: StructuredReportFixtures.scripts)
        let events = await AgentLoopTestSupport.collectEvents(prompt: .user("报告计划及测试"),
            context: AgentContext(systemPrompt: "test", workingDirectory: root),
            config: AgentLoopConfig(model: AgentLoopTestSupport.defaultModel, llm: llm,
                tools: AgentSessionFactory.codingTools(workingDirectory: root, llm: llm, model: AgentLoopTestSupport.defaultModel)))
        let ends = events.compactMap { event -> ToolResult? in
            if case let .toolExecutionEnd(_, _, result) = event { return result }; return nil
        }
        let messages = events.compactMap { event -> ToolResultMessage? in
            if case let .messageEnd(.toolResult(result)) = event { return result }; return nil
        }
        #expect(ends.count == 2 && messages.count == 2)
        #expect(ends.first?.progressReport?.completedCount == 1)
        #expect(ends.last?.testReport?.failed == 2)
        for (end, message) in zip(ends, messages) {
            #expect(message.progressReport == end.progressReport)
            #expect(message.testReport == end.testReport)
        }
        let final = try #require(events.compactMap { event -> AgentContext? in
            if case let .contextSnapshot(context) = event { return context }; return nil
        }.last)
        let finalResults = final.messages.compactMap { message -> ToolResultMessage? in
            if case let .toolResult(result) = message { return result }; return nil
        }
        #expect(finalResults == messages)
        var persisted = SessionContext(header: SessionHeader(workingDirectory: root))
        var leaf: String?
        SessionManager.syncMessages(final.messages, into: &persisted, leafID: &leaf)
        let file = root.appendingPathComponent("session.jsonl")
        let store = JSONLSessionStore()
        try store.save(persisted, to: file)
        let restored = SessionManager.messages(from: try store.load(from: file)).compactMap { message -> ToolResultMessage? in
            if case let .toolResult(result) = message { return result }; return nil
        }
        // JSONL 日期精度既有规则不变；这里只核验完整报告。
        #expect(restored.map(\.progressReport) == messages.map(\.progressReport))
        #expect(restored.map(\.testReport) == messages.map(\.testReport))
    }

    @Test("新增工具不绕过 beforeToolCall 或配置的审批拒绝", arguments: [false, true])
    func gate(deny: Bool) async throws {
        let root = try StructuredReportFixtures.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = await AgentLoopTestSupport.collectEvents(prompt: .user("test"),
            context: AgentContext(systemPrompt: "test", workingDirectory: root),
            config: AgentLoopConfig(model: AgentLoopTestSupport.defaultModel,
                llm: MockLLMProviderBox(scripts: StructuredReportFixtures.scripts),
                tools: [UpdatePlanTool(), ReadTestReportTool()],
                toolPolicy: ToolPolicyRules(requireApprovalFor: ["update_plan", "read_test_report"]),
                beforeToolCall: deny ? nil : { @Sendable _, _ in BeforeToolCallDecision(block: true) },
                requestToolApproval: { _ in .deny },
                dangerEvaluator: DangerEvaluator(policy: ApprovalPolicy(riskRules: [],
                    toolBaseline: ["update_plan": deny ? .medium : .low, "read_test_report": deny ? .medium : .low]))))
        let results = events.compactMap { event -> ToolResult? in
            if case let .toolExecutionEnd(_, _, result) = event { return result }; return nil
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.isError && $0.progressReport == nil && $0.testReport == nil })
        let requests = events.filter { if case .toolApprovalRequired = $0 { return true }; return false }
        #expect(requests.count == (deny ? 2 : 0))
    }

    @Test("注册和历史策略默认分类，显式覆盖优先")
    @MainActor func registration() throws {
        let root = URL(fileURLWithPath: "/unused")
        let registries = [
            BuiltInTools.codingTools(for: root).map(\.definition),
            AgentSessionFactory.codingTools(workingDirectory: root, llm: MockLLMProviderBox(scripts: []),
                model: AgentLoopTestSupport.defaultModel).map(\.definition),
            ChatRoomLoop.chatroomTools(projectURL: root, additional: []).map(\.definition),
            ChatRoomTools.allDefinitions()
        ]
        for tools in registries {
            for name in ["update_plan", "read_test_report"] {
                #expect(tools.filter { $0.name == name }.count == 1)
                let definition = try #require(tools.first { $0.name == name })
                #expect(definition.parameters.objectValue?["type"]?.stringValue == "object")
                _ = try definition.parameters.toJSONData()
                #expect(ApprovalPolicy(toolBaseline: [:]).baseline(for: name) == .low)
                #expect(ApprovalPolicy(toolBaseline: [name: .high]).baseline(for: name) == .high)
                #expect(!ToolPolicyRules.codingAgentDefault.requiresApproval(toolName: name))
                #expect(ToolPolicyRules(requireApprovalFor: [name]).requiresApproval(toolName: name))
            }
        }
    }

    @Test("旧字段缺失/null 兼容，报告 Codable 往返及 provider 隔离")
    func serialization() throws {
        for suffix in ["", ",\"progressReport\":null,\"testReport\":null"] {
            let old = "{\"toolCallID\":\"old\",\"toolName\":\"read\",\"content\":\"ok\",\"isError\":false,\"timestamp\":0\(suffix)}"
            let result = try JSONDecoder().decode(ToolResultMessage.self, from: Data(old.utf8))
            #expect(result.progressReport == nil && result.testReport == nil)
            let room = "{\"toolCallID\":\"old\",\"output\":\"ok\",\"isError\":false\(suffix)}"
            let roomResult = try JSONDecoder().decode(ChatRoomToolResult.self, from: Data(room.utf8))
            #expect(roomResult.progressReport == nil && roomResult.testReport == nil)
            let tool = try JSONDecoder().decode(ToolResult.self, from: Data("{\"content\":\"old\"\(suffix)}".utf8))
            #expect(tool.progressReport == nil && tool.testReport == nil)
        }
        let progress = ProgressReport(steps: [.init(id: "PRIVATE_ID", title: "PRIVATE_TITLE", status: .completed)])
        let tests = TestReport(path: "PRIVATE_PATH", passed: 1, failed: 2, skipped: 3)
        let result = ToolResultMessage(toolCallID: "r", toolName: "report", content: "PUBLIC_OUTPUT", isError: false,
            progressReport: progress, testReport: tests)
        #expect(try JSONDecoder().decode(ToolResultMessage.self, from: JSONEncoder().encode(result)) == result)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tests)) as? [String: Any])
        #expect(Set(json.keys) == ["path", "passed", "failed", "skipped", "total", "source"])
        #expect(json["total"] as? Int == 6 && json["source"] as? String == "JUnit")
        let progressJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any])
        #expect(Set(progressJSON.keys) == ["steps", "source"])
        #expect(progressJSON["source"] as? String == "agentReport")
        let messages: [AgentMessage] = [.toolResult(result)]
        for payload in [AnthropicMessageEncoder.encodeMessages(messages), OpenAIMessageEncoder.encodeMessages(messages),
                        ResponsesMessageEncoder.encodeInput(messages)] {
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            #expect(encoded.contains("PUBLIC_OUTPUT"))
            for forbidden in ["PRIVATE_", "progressReport", "testReport", "agentReport", "JUnit"] {
                #expect(!encoded.contains(forbidden))
            }
        }
    }
}

private struct StructuredReportLegacyFactory: ChatRoomLLMProviderFactory {
    let llm: MockLLMProviderBox
    let manager: ChatRoomApprovalManager
    func createProvider(profileID: String, modelID: String, projectPath: String,
                        roleID: String, roleName: String, thinkingLevel: ThinkingLevel?) throws -> any ChatRoomLLMProvider {
        ChatRoomLLMProviderImpl(provider: llm, modelConfig: AgentLoopTestSupport.defaultModel,
            toolExecutor: ChatRoomToolExecutor(projectPath: projectPath, approvalManager: manager))
    }
}

@Suite("聊天室结构化报告全路径")
@MainActor
struct ChatRoomStructuredReportTests {
    @Test("engine/legacy 均保存实际报告并经 JSONL 冷恢复", arguments: [false, true])
    func persistence(legacy: Bool) async throws {
        let root = try StructuredReportFixtures.project()
        defer { try? FileManager.default.removeItem(at: root) }
        try StructuredReportFixtures.xml.write(to: root.appendingPathComponent("report.xml"), atomically: true, encoding: .utf8)
        let store = ChatRoomStore(baseDirectory: root.appendingPathComponent("rooms"))
        let role = ChatRoomRole(id: "role", name: "Role", description: "", systemPrompt: "",
            providerProfileID: "mock", modelID: "mock")
        let room = ChatRoom(name: "reports", roles: [role], projectPath: root.path)
        try store.save(room)
        let policy = ApprovalPolicyStore(fileURL: root.appendingPathComponent("policy.json"))
        try policy.save(ApprovalPolicy(riskRules: [], toolBaseline: [:]))
        let manager = ChatRoomApprovalManager(policyStore: policy)
        let runtime = ChatRoomRuntime(chatroom: room)
        let llm = MockLLMProviderBox(scripts: StructuredReportFixtures.scripts)
        let loop: ChatRoomLoop
        if legacy {
            loop = ChatRoomLoop(store: store, llmFactory: StructuredReportLegacyFactory(llm: llm, manager: manager), approvalManager: manager)
        } else {
            loop = ChatRoomLoop(store: store, approvalManager: manager, engineProvider: { _ in
                ChatRoomRoleEngine(llm: llm, model: AgentLoopTestSupport.defaultModel)
            })
        }
        try await loop.triggerSpeaker(roleID: "role", runtime: runtime)
        let results = runtime.messages.flatMap { $0.toolResults ?? [] }
        #expect(results.count == 2)
        #expect(results.first?.progressReport?.completedCount == 1)
        #expect(results.first?.progressReport?.source == .agentReport)
        #expect(results.last?.testReport == TestReport(path: "report.xml", passed: 1, failed: 2, skipped: 1))
        #expect(manager.pendingApprovals.isEmpty)
        let loaded = try store.loadMessages(for: room.id).flatMap { $0.toolResults ?? [] }
        #expect(loaded == results)
    }

    @Test("legacy 显式高风险配置仍可拒绝，不生成报告", arguments: ["update_plan", "read_test_report"])
    func legacyGate(name: String) async throws {
        let root = try StructuredReportFixtures.project()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ApprovalPolicyStore(fileURL: root.appendingPathComponent("policy.json"))
        try policy.save(ApprovalPolicy(riskRules: [], toolBaseline: [name: .high]))
        let manager = ChatRoomApprovalManager(policyStore: policy)
        let executor = ChatRoomToolExecutor(projectPath: root.path, approvalManager: manager)
        let call = try #require(StructuredReportFixtures.calls.first { $0.name == name })
        let task = Task { try await executor.execute(toolCall: call) }
        defer { task.cancel() }
        for _ in 0..<200 {
            if !manager.pendingApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = try #require(manager.pendingApprovals.first)
        manager.reject(id: pending.id)
        let result = try await task.value
        #expect(result.isError && result.progressReport == nil && result.testReport == nil)
    }
}