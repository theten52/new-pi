import Foundation
import Testing
@testable import NewPiCore

@Suite("AgentLoop")
struct AgentLoopTests {
    @Test("simple text reply without tools")
    func simpleTextReply() async {
        let llm = MockLLMProviderBox(scripts: [[
            .textDelta("Hello"),
            .textDelta(" there"),
            .completed(stopReason: .stop, usage: UsageStats(inputTokens: 1, outputTokens: 2)),
        ]])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm
        )
        let context = AgentContext(systemPrompt: "You are helpful.")

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("Hi"),
            context: context,
            config: config
        )

        #expect(events.contains { if case .agentStart = $0 { true } else { false } })
        #expect(events.contains { if case .agentEnd = $0 { true } else { false } })
        #expect(events.filter { AgentLoopTestSupport.label(for: $0) == "textDelta" }.count == 2)

        if let snapshot = events.compactMap({
            if case let .contextSnapshot(context) = $0 { context } else { nil }
        }).last {
            #expect(snapshot.messages.count == 2)
            #expect(snapshot.messages[0].roleLabel == "user")
            #expect(snapshot.messages[1].roleLabel == "assistant")
        } else {
            Issue.record("Missing context snapshot")
        }
    }

    @Test("single tool call then final reply")
    func singleToolCall() async {
        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "echo", arguments: .object(["text": .string("ping")]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("Echo was ping"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: [EchoTool()]
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("echo ping"),
            context: AgentContext(systemPrompt: "test"),
            config: config
        )

        #expect(events.contains { if case .toolExecutionStart(_, "echo", _) = $0 { true } else { false } })
        #expect(events.contains { if case .toolExecutionEnd(_, "echo", let result) = $0 { result.content == "ping" } else { false } })
        #expect(events.filter { AgentLoopTestSupport.label(for: $0) == "turnStart" }.count == 2)
    }

    @Test("parallel tool calls")
    func parallelToolCalls() async {
        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "a", name: "echo", arguments: .object(["text": .string("one")]))),
                .toolCall(ToolCallContent(id: "b", name: "echo", arguments: .object(["text": .string("two")]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("done"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: [EchoTool()],
            toolExecution: .parallel
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("parallel"),
            context: AgentContext(systemPrompt: "test"),
            config: config
        )

        let toolEnds = events.compactMap { event -> String? in
            if case let .toolExecutionEnd(_, "echo", result) = event { return result.content }
            return nil
        }
        #expect(Set(toolEnds) == Set(["one", "two"]))
    }

    @Test("tool failure is reported as tool result error")
    func toolFailure() async {
        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "fail", arguments: .object([:]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("handled"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: [FailingTool()]
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("fail please"),
            context: AgentContext(systemPrompt: "test"),
            config: config
        )

        #expect(events.contains {
            if case let .toolExecutionEnd(_, "fail", result) = $0 { result.isError } else { false }
        })
    }

    @Test("beforeToolCall can block execution")
    func blockedToolCall() async {
        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "echo", arguments: .object(["text": .string("nope")]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("blocked"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: [EchoTool()],
            beforeToolCall: { _, _ in
                BeforeToolCallDecision(block: true, reason: "denied")
            }
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("try echo"),
            context: AgentContext(systemPrompt: "test"),
            config: config
        )

        #expect(events.contains {
            if case let .toolExecutionEnd(_, "echo", result) = $0 {
                result.isError && result.content == "denied"
            } else {
                false
            }
        })
    }

    @Test("unknown tool returns error result instead of aborting agent")
    func unknownTool() async {
        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "missing", arguments: .object([:]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("handled"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: [EchoTool()]
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("try missing tool"),
            context: AgentContext(systemPrompt: "test"),
            config: config
        )

        #expect(!events.contains { if case .error = $0 { true } else { false } })
        #expect(events.contains {
            if case let .toolExecutionEnd(_, "missing", result) = $0 {
                result.isError && result.content.contains("Tool not found")
            } else {
                false
            }
        })
    }

    @Test("steering message is injected after tool execution")
    func steeringAfterTools() async {
        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "echo", arguments: .object(["text": .string("first")]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("course corrected"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: [EchoTool()]
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("start"),
            context: AgentContext(systemPrompt: "test"),
            config: config,
            steeringProvider: {
                .user("Stop and do this instead")
            }
        )

        if let snapshot = events.compactMap({
            if case let .contextSnapshot(context) = $0 { context } else { nil }
        }).last {
            let userMessages = snapshot.messages.compactMap { message -> String? in
                if case let .user(user) = message { return user.content }
                return nil
            }
            #expect(userMessages.contains("Stop and do this instead"))
        } else {
            Issue.record("Missing context snapshot")
        }
    }

    @Test("LLM failure keeps user message in final snapshot")
    func llmFailureKeepsUserMessageInSnapshot() async {
        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: ThrowingLLMProvider()
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("Hi"),
            context: AgentContext(systemPrompt: "test"),
            config: config
        )

        #expect(events.contains { if case .error = $0 { true } else { false } })

        if let snapshot = events.compactMap({
            if case let .contextSnapshot(context) = $0 { context } else { nil }
        }).last {
            // 回归：catch 分支曾引用 do 块外的初始参数，把已提交的用户消息回滚掉。
            #expect(snapshot.messages.count == 1)
            #expect(snapshot.messages.first?.roleLabel == "user")
        } else {
            Issue.record("Missing context snapshot")
        }
    }
}
