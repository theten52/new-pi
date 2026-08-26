import Foundation
import Testing
@testable import NewPiCore

@Suite("SessionLabelService")
struct SessionLabelServiceTests {
    @Test("firstExchange finds opening user and assistant messages")
    func firstExchange() {
        let messages: [AgentMessage] = [
            .user("帮我写一个 Swift 排序函数"),
            .assistant(
                AssistantMessage(
                    text: "好的，我来帮你写。",
                    provider: "anthropic",
                    modelID: "claude",
                    stopReason: .stop
                )
            ),
            .user("再加单元测试"),
        ]

        let exchange = SessionLabelService.firstExchange(from: messages)
        #expect(exchange?.user == "帮我写一个 Swift 排序函数")
        #expect(exchange?.assistant == "好的，我来帮你写。")
    }

    @Test("firstExchange ignores tool-only assistant turns")
    func firstExchangeSkipsEmptyAssistant() {
        let messages: [AgentMessage] = [
            .user("run tests"),
            .assistant(
                AssistantMessage(
                    text: "",
                    toolCalls: [
                        ToolCallContent(
                            id: "1",
                            name: "bash",
                            arguments: .object(["command": .string("swift test")])
                        ),
                    ],
                    provider: "anthropic",
                    modelID: "claude",
                    stopReason: .stop
                )
            ),
            .toolResult(
                ToolResultMessage(
                    toolCallID: "1",
                    toolName: "bash",
                    content: "ok",
                    isError: false
                )
            ),
            .assistant(
                AssistantMessage(
                    text: "Tests passed.",
                    provider: "anthropic",
                    modelID: "claude",
                    stopReason: .stop
                )
            ),
        ]

        let exchange = SessionLabelService.firstExchange(from: messages)
        #expect(exchange?.user == "run tests")
        #expect(exchange?.assistant == "Tests passed.")
    }

    @Test("sanitize trims quotes and length")
    func sanitize() {
        #expect(SessionLabelService.sanitize("  \"Swift 排序\"  ") == "Swift 排序")
        #expect(SessionLabelService.sanitize(String(repeating: "a", count: 50)).count == 40)
    }
}
