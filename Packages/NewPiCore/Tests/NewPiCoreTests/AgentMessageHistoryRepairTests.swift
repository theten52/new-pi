import Foundation
import Testing
@testable import NewPiCore

@Suite("AgentMessageHistoryRepair")
struct AgentMessageHistoryRepairTests {
    @Test("inserts error tool results for orphaned assistant tool calls")
    func repairsOrphans() {
        var messages: [AgentMessage] = [
            .user("go"),
            .assistant(
                AssistantMessage(
                    text: "Running tools",
                    toolCalls: [
                        ToolCallContent(id: "call_a", name: "bash", arguments: .object([:])),
                        ToolCallContent(id: "call_b", name: "read", arguments: .object(["path": .string("README.md")])),
                    ],
                    provider: "openaiCompatible",
                    modelID: "test",
                    stopReason: .stop
                )
            ),
            .user("next question"),
        ]

        AgentMessageHistoryRepair.repairOrphanedToolCalls(in: &messages)

        #expect(messages.count == 5)
        guard case let .toolResult(first) = messages[2],
              case let .toolResult(second) = messages[3] else {
            Issue.record("Expected repaired tool results")
            return
        }
        #expect(first.toolCallID == "call_a")
        #expect(second.toolCallID == "call_b")
        #expect(first.isError)
        #expect(second.isError)
        guard case let .user(user) = messages[4] else {
            Issue.record("Expected trailing user message")
            return
        }
        #expect(user.content == "next question")
    }

    @Test("does not duplicate existing tool results")
    func leavesCompleteHistory() {
        var messages: [AgentMessage] = [
            .assistant(
                AssistantMessage(
                    text: "",
                    toolCalls: [
                        ToolCallContent(id: "call_1", name: "read", arguments: .object(["path": .string("a.txt")])),
                    ],
                    provider: "openaiCompatible",
                    modelID: "test",
                    stopReason: .toolUse
                )
            ),
            .toolResult(
                ToolResultMessage(toolCallID: "call_1", toolName: "read", content: "ok", isError: false)
            ),
        ]

        AgentMessageHistoryRepair.repairOrphanedToolCalls(in: &messages)
        #expect(messages.count == 2)
    }
}

@Suite("OpenAIStreamParser stopReason")
struct OpenAIStreamParserStopReasonTests {
    @Test("treats streamed tool calls as toolUse even when finish_reason is stop")
    func toolCallsWithStopReason() {
        let decoder = OpenAISSEDecoder()
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]}}]}",
            "",
            "data: {\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2}}",
            "",
        ]

        var parser = OpenAIStreamParser()
        let events = parser.parse(events: decoder.decodeLines(lines))
        #expect(events.contains {
            if case let .toolCall(call) = $0 {
                call.name == "read" && call.arguments.objectValue?["path"]?.stringValue == "README.md"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case let .completed(reason, _) = $0 {
                reason == .toolUse
            } else {
                false
            }
        })
    }

    @Test("accumulates tool arguments across multiple SSE batches")
    func splitBatchArguments() {
        var parser = OpenAIStreamParser()

        let first = parser.parse(events: [
            .toolCallDelta(index: 0, id: "call_1", name: "read", argumentsDelta: nil),
        ])
        #expect(first.isEmpty)

        let second = parser.parse(events: [
            .toolCallDelta(index: 0, id: nil, name: nil, argumentsDelta: "{\"path\":\"README.md\"}"),
        ])
        #expect(second.isEmpty)

        let third = parser.parse(events: [
            .completed(reason: "tool_calls", inputTokens: 1, outputTokens: 2),
        ])
        #expect(third.contains {
            if case let .toolCall(call) = $0 {
                call.arguments.objectValue?["path"]?.stringValue == "README.md"
            } else {
                false
            }
        })
    }

    @Test("maps reasoning_content deltas to thinkingDelta")
    func reasoningContentDelta() {
        let decoder = OpenAISSEDecoder()
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Let me inspect\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"}}]}",
            "",
            "data: {\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}",
            "",
        ]

        var parser = OpenAIStreamParser()
        let events = parser.parse(events: decoder.decodeLines(lines))
        #expect(events.contains { if case let .thinkingDelta(text) = $0 { text == "Let me inspect" } else { false } })
        #expect(events.contains { if case let .textDelta(text) = $0 { text == "Done" } else { false } })
    }
}

@Suite("OpenAIMessageEncoder reasoning")
struct OpenAIMessageEncoderReasoningTests {
    @Test("round-trips assistant reasoning_content for tool history")
    func roundTripsReasoning() {
        let messages: [AgentMessage] = [
            .assistant(
                AssistantMessage(
                    text: "",
                    reasoningContent: "Need to read files first.",
                    toolCalls: [
                        ToolCallContent(id: "call_1", name: "read", arguments: .object(["path": .string("a.swift")])),
                    ],
                    provider: "openaiCompatible",
                    modelID: "deepseek-v4-flash",
                    stopReason: .toolUse
                )
            ),
        ]

        let encoded = OpenAIMessageEncoder.encodeMessages(messages)
        #expect(encoded.count == 1)
        #expect(encoded[0]["reasoning_content"] as? String == "Need to read files first.")
        #expect(encoded[0]["tool_calls"] != nil)
    }
}
