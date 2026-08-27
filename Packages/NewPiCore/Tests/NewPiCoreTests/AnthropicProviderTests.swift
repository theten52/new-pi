import Foundation
import Testing
@testable import NewPiCore

@Suite("AnthropicMessageEncoder")
struct AnthropicMessageEncoderTests {
    @Test("encodes assistant tool calls as structured blocks")
    func assistantToolCalls() {
        let messages: [AgentMessage] = [
            .user("run echo"),
            .assistant(
                AssistantMessage(
                    text: "I'll echo that.",
                    toolCalls: [
                        ToolCallContent(id: "toolu_1", name: "echo", arguments: .object(["text": .string("ping")])),
                    ],
                    provider: "anthropic",
                    modelID: "claude-sonnet-4-20250514",
                    stopReason: .toolUse
                )
            ),
            .toolResult(
                ToolResultMessage(toolCallID: "toolu_1", toolName: "echo", content: "ping", isError: false)
            ),
        ]

        let encoded = AnthropicMessageEncoder.encodeMessages(messages)
        #expect(encoded.count == 3)

        let assistant = encoded[1]
        #expect(assistant["role"] as? String == "assistant")
        let content = assistant["content"] as? [[String: Any]]
        #expect(content?.contains(where: { $0["type"] as? String == "tool_use" }) == true)

        let toolResults = encoded[2]
        #expect(toolResults["role"] as? String == "user")
        let toolResultBlocks = toolResults["content"] as? [[String: Any]]
        #expect(toolResultBlocks?.first?["type"] as? String == "tool_result")
    }
}

@Suite("AnthropicStreamParser")
struct AnthropicStreamParserTests {
    @Test("parses text and completion events")
    func textCompletion() {
        var decoder = AnthropicSSEDecoder()
        let lines = [
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":10,\"output_tokens\":3}}",
            "",
        ]

        var parser = AnthropicStreamParser()
        let events = parser.parse(events: decoder.decodeLines(lines))
        #expect(events.contains { if case let .textDelta(text) = $0 { text == "Hello" } else { false } })
        #expect(events.contains {
            if case let .completed(reason, usage) = $0 {
                reason == .stop && usage.inputTokens == 10 && usage.outputTokens == 3
            } else {
                false
            }
        })
    }

    @Test("parses tool use stream")
    func toolUse() {
        var decoder = AnthropicSSEDecoder()
        let lines = [
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"echo\",\"input\":{}}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"ping\\\"}\"}}",
            "",
            "event: content_block_stop",
            "data: {\"type\":\"content_block_stop\",\"index\":1}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":8}}",
            "",
        ]

        var parser = AnthropicStreamParser()
        let events = parser.parse(events: decoder.decodeLines(lines))
        #expect(events.contains {
            if case let .toolCall(call) = $0 {
                call.id == "toolu_1" && call.name == "echo"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case let .completed(reason, _) = $0 { reason == .toolUse } else { false }
        })
    }

    @Test("tool use survives per-block incremental feeding (production path)")
    func toolUseIncrementalBlocks() {
        // 回归：生产路径按 SSE 块逐个调用 decodeLines/parse，
        // 此前 openToolBlocks/toolInputs 是函数局部状态，跨块丢失导致工具调用永远丢失。
        var decoder = AnthropicSSEDecoder()
        var parser = AnthropicStreamParser()

        let blocks: [[String]] = [
            [
                "event: content_block_start",
                "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"echo\",\"input\":{}}}",
            ],
            [
                "event: content_block_delta",
                "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\"}}",
            ],
            [
                "event: content_block_delta",
                "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"ping\\\"}\"}}",
            ],
            [
                "event: content_block_stop",
                "data: {\"type\":\"content_block_stop\",\"index\":1}",
            ],
            [
                "event: message_delta",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":8}}",
            ],
            [
                "event: message_stop",
                "data: {\"type\":\"message_stop\"}",
            ],
        ]

        var events: [LLMStreamEvent] = []
        for block in blocks {
            events += parser.parse(events: decoder.decodeLines(block))
        }
        events += parser.finish()

        let toolCalls = events.compactMap { event -> ToolCallContent? in
            if case let .toolCall(call) = event { call } else { nil }
        }
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.id == "toolu_1")
        #expect(toolCalls.first?.arguments.objectValue?["text"] == .string("ping"))

        let completions = events.filter { if case .completed = $0 { true } else { false } }
        #expect(completions.count == 1)
        if case let .completed(reason, usage) = completions.first {
            #expect(reason == .toolUse)
            #expect(usage.outputTokens == 8)
        }
    }

    @Test("finish emits completion when stream ends without message_delta")
    func finishEmitsCompletionOnTruncatedStream() {
        var decoder = AnthropicSSEDecoder()
        var parser = AnthropicStreamParser()
        var events = parser.parse(events: decoder.decodeLines([
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
        ]))
        events += parser.finish()
        let completions = events.filter { if case .completed = $0 { true } else { false } }
        #expect(completions.count == 1)
    }
}

@Suite("CredentialResolver")
struct CredentialResolverTests {
    @Test("prefers environment variable over keychain")
    func environmentFirst() async throws {
        let store = InMemoryCredentialStore(secrets: ["anthropic-api-key": "from-keychain"])
        let resolver = CredentialResolver(
            store: store,
            environment: { ["ANTHROPIC_API_KEY": "from-env"] }
        )

        let key = try await resolver.apiKey(for: .anthropic)
        #expect(key == "from-env")
    }

    @Test("falls back to keychain")
    func keychainFallback() async throws {
        let store = InMemoryCredentialStore(secrets: ["anthropic-api-key": "from-keychain"])
        let resolver = CredentialResolver(store: store, environment: { [:] })

        let key = try await resolver.apiKey(for: .anthropic)
        #expect(key == "from-keychain")
    }
}
