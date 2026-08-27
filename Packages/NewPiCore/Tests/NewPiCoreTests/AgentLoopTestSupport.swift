import Foundation
import NewPiCore

struct MockLLMProviderBox: LLMProvider {
    private let state: MockLLMState

    init(scripts: [[LLMStreamEvent]]) {
        self.state = MockLLMState(scripts: scripts)
    }

    func stream(
        model: ModelConfig,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let script = try await state.nextScript()
                    for event in script {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private actor MockLLMState {
    private var scripts: [[LLMStreamEvent]]

    init(scripts: [[LLMStreamEvent]]) {
        self.scripts = scripts
    }

    func nextScript() throws -> [LLMStreamEvent] {
        guard !scripts.isEmpty else {
            return [.textDelta("Done."), .completed(stopReason: .stop, usage: UsageStats())]
        }
        return scripts.removeFirst()
    }
}

struct EchoTool: AgentTool {
    let name = "echo"
    let definition = ToolDefinition(
        name: "echo",
        description: "Echo input text",
        parameters: .object(["text": .string("")])
    )

    func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        let text = arguments.objectValue?["text"]?.stringValue ?? ""
        onUpdate?(ToolProgress(message: "echoing"))
        return ToolResult(content: text)
    }
}

struct FailingTool: AgentTool {
    let name = "fail"
    let definition = ToolDefinition(
        name: "fail",
        description: "Always fails",
        parameters: .object([:])
    )

    func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        throw AgentError.invalidState("boom")
    }
}

struct ThrowingLLMProvider: LLMProvider {
    func stream(
        model: ModelConfig,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AgentError.llmFailed("boom"))
        }
    }
}

enum AgentLoopTestSupport {
    static let defaultModel = ModelConfig(provider: "mock", modelID: "mock-1")

    static func collectEvents(
        prompt: AgentMessage,
        context: AgentContext,
        config: AgentLoopConfig,
        steeringProvider: (@Sendable () async -> AgentMessage?)? = nil
    ) async -> [AgentEvent] {
        let loop = AgentLoop()
        var events: [AgentEvent] = []
        for await event in loop.run(
            prompt: prompt,
            context: context,
            config: config,
            steeringProvider: steeringProvider
        ) {
            events.append(event)
        }
        return events
    }

    static func hasEventSequence(_ events: [AgentEvent], _ labels: [String]) -> Bool {
        let mapped = events.map { label(for: $0) }
        return mapped == labels
    }

    static func label(for event: AgentEvent) -> String {
        switch event {
        case .agentStart: "agentStart"
        case .agentEnd: "agentEnd"
        case .turnStart: "turnStart"
        case .turnEnd: "turnEnd"
        case .messageStart: "messageStart"
        case .messageEnd: "messageEnd"
        case .textDelta: "textDelta"
        case .thinkingDelta: "thinkingDelta"
        case .toolExecutionStart: "toolExecutionStart"
        case .toolApprovalRequired: "toolApprovalRequired"
        case .toolExecutionUpdate: "toolExecutionUpdate"
        case .toolExecutionEnd: "toolExecutionEnd"
        case .contextSnapshot: "contextSnapshot"
        case .error: "error"
        }
    }
}
