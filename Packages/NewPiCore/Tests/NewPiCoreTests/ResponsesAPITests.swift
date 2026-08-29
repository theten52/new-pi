import Foundation
import Testing
@testable import NewPiCore

@Suite("ResponsesEndpoint")
struct ResponsesEndpointTests {
    @Test("normalizes DeepSeek origin to /responses")
    func resolveDeepSeekOrigin() throws {
        let profile = ProviderProfile(
            name: "DeepSeek",
            preset: .openaiCompatible,
            modelID: "deepseek-v4-flash",
            options: [
                "baseURL": "https://api.deepseek.com",
                "apiMode": ProviderAPIMode.responses.rawValue,
            ]
        )
        let url = try ResponsesEndpoint.resolveURL(for: profile)
        #expect(url.absoluteString == "https://api.deepseek.com/responses")
    }

    @Test("strips chat completions suffix before appending /responses")
    func stripChatCompletionsSuffix() throws {
        let profile = ProviderProfile(
            name: "DeepSeek",
            preset: .openaiCompatible,
            modelID: "deepseek-v4-flash",
            options: [
                "baseURL": "https://api.deepseek.com/v1/chat/completions",
                "apiMode": ProviderAPIMode.responses.rawValue,
            ]
        )
        let url = try ResponsesEndpoint.resolveURL(for: profile)
        #expect(url.absoluteString == "https://api.deepseek.com/responses")
    }
}

@Suite("ResponsesMessageEncoder")
struct ResponsesMessageEncoderTests {
    @Test("encodes user, assistant, tool call, and tool output items")
    func encodeConversation() {
        let messages: [AgentMessage] = [
            .user("hello"),
            .assistant(
                AssistantMessage(
                    text: "hi",
                    reasoningContent: "thinking",
                    toolCalls: [
                        ToolCallContent(
                            id: "call_1",
                            name: "read",
                            arguments: .object(["path": .string("a.txt")])
                        ),
                    ],
                    provider: "deepseek",
                    modelID: "deepseek-v4-flash",
                    stopReason: .stop
                )
            ),
            .toolResult(
                ToolResultMessage(
                    toolCallID: "call_1",
                    toolName: "read",
                    content: "file contents",
                    isError: false
                )
            ),
        ]

        let items = ResponsesMessageEncoder.encodeInput(messages)
        #expect(items.count == 5)
        #expect(items[0]["type"] as? String == "message")
        #expect(items[1]["type"] as? String == "reasoning")
        #expect(items[2]["type"] as? String == "message")
        #expect(items[3]["type"] as? String == "function_call")
        #expect(items[4]["type"] as? String == "function_call_output")
    }
}

@Suite("ResponsesSSEDecoder")
struct ResponsesSSEDecoderTests {
    @Test("parses text, reasoning, tool call, and completion events")
    func decodeStream() {
        let lines = [
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}",
            "",
            "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"think\"}",
            "",
            "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"call_id\":\"call_1\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}",
            "",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}",
            "",
        ]

        let decoder = ResponsesSSEDecoder()
        let events = decoder.decodeLines(lines)
        #expect(events.contains { if case let .textDelta(text) = $0 { text == "Hi" } else { false } })
        #expect(events.contains { if case let .reasoningDelta(text) = $0 { text == "think" } else { false } })
        #expect(events.contains {
            if case let .functionCallArgumentsDone(_, callID, name, _) = $0 {
                callID == "call_1" && name == "bash"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case let .completed(status, _, input, output, _) = $0 {
                status == "completed" && input == 10 && output == 5
            } else {
                false
            }
        })
    }
}

@Suite("ResponsesStreamParser")
struct ResponsesStreamParserTests {
    @Test("maps tool call completion to LLMStreamEvent toolCall")
    func toolCall() {
        var parser = ResponsesStreamParser()
        let events = parser.parse(events: [
            .functionCallArgumentsDone(
                outputIndex: 0,
                callID: "call_1",
                name: "read",
                arguments: "{\"path\":\"a.txt\"}"
            ),
            .completed(status: "completed", incompleteReason: nil, inputTokens: 1, outputTokens: 2),
        ])

        #expect(events.contains {
            if case let .toolCall(call) = $0 {
                call.id == "call_1" && call.name == "read"
            } else {
                false
            }
        })
        #expect(events.contains {
            if case let .completed(stopReason, _) = $0 {
                stopReason == .toolUse
            } else {
                false
            }
        })
    }
}

@Suite("ProviderAPIMode profile")
struct ProviderAPIModeProfileTests {
    @Test("defaults to chat completions when option missing")
    func defaultMode() {
        let profile = ProviderProfile(
            name: "OpenAI Compatible",
            preset: .openaiCompatible,
            modelID: "gpt-4o"
        )
        #expect(profile.apiMode == .chatCompletions)
    }

    @Test("DeepSeek Responses quick setup uses responses mode")
    func deepSeekResponsesQuickSetup() {
        let profile = ProviderProfile.makeDefault(
            from: ProviderPresetCatalog.deepSeekResponsesQuickSetup,
            name: "DeepSeek Responses"
        )
        #expect(profile.apiMode == .responses)
        #expect(profile.option(.baseURL) == "https://api.deepseek.com")
        #expect(profile.maxTokens == 16_384)
    }
}

@Suite("LLMProviderFactory responses")
struct LLMProviderFactoryResponsesTests {
    @Test("responses apiMode builds ResponsesAPIProvider")
    func responsesFactory() throws {
        var profile = ProviderProfile.makeDefault(
            from: ProviderPresetCatalog.deepSeekResponsesQuickSetup,
            name: "DeepSeek Responses"
        )
        profile.setAPIMode(.responses)
        let resolver = ProviderCredentialResolver(store: InMemoryCredentialStore(secrets: [
            ProviderCredentialResolver.keychainAccount(for: profile.id): "sk-test",
        ]))
        let provider = try LLMProviderFactory.make(profile: profile, credentialResolver: resolver)
        #expect(provider is ResponsesAPIProvider)
    }
}
