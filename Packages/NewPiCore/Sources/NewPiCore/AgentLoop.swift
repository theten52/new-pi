import Foundation

public struct AgentLoop: Sendable {
    public init() {}

    public func run(
        prompt: AgentMessage,
        context: AgentContext,
        config: AgentLoopConfig,
        steeringProvider: (@Sendable () async -> AgentMessage?)? = nil
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    var context = context
                    continuation.yield(.agentStart)

                    try appendMessage(prompt, to: &context, continuation: continuation)

                    var shouldContinue = true
                    while shouldContinue {
                        try Task.checkCancellation()
                        continuation.yield(.turnStart)

                        let assistant = try await streamAssistant(
                            context: context,
                            config: config,
                            continuation: continuation
                        )
                        try appendMessage(.assistant(assistant), to: &context, continuation: continuation)

                        if assistant.stopReason == .toolUse, !assistant.toolCalls.isEmpty {
                            try await executeToolCalls(
                                assistant.toolCalls,
                                context: context,
                                config: config,
                                continuation: continuation,
                                messageSink: &context.messages
                            )

                            if let steeringProvider,
                               let steeringMessage = await steeringProvider() {
                                try appendMessage(steeringMessage, to: &context, continuation: continuation)
                            }
                            continuation.yield(.turnEnd)
                            continue
                        }

                        shouldContinue = false
                        continuation.yield(.turnEnd)
                    }

                    continuation.yield(.contextSnapshot(context))
                    continuation.yield(.agentEnd)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.error(.aborted))
                    continuation.yield(.contextSnapshot(context))
                    continuation.yield(.agentEnd)
                    continuation.finish()
                } catch let error as AgentError {
                    continuation.yield(.error(error))
                    continuation.yield(.contextSnapshot(context))
                    continuation.yield(.agentEnd)
                    continuation.finish()
                } catch {
                    continuation.yield(.error(.llmFailed(error.localizedDescription)))
                    continuation.yield(.contextSnapshot(context))
                    continuation.yield(.agentEnd)
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func appendMessage(
        _ message: AgentMessage,
        to context: inout AgentContext,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) throws {
        continuation.yield(.messageStart(message))
        context.messages.append(message)
        continuation.yield(.messageEnd(message))
    }

    private func streamAssistant(
        context: AgentContext,
        config: AgentLoopConfig,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> AssistantMessage {
        var text = ""
        var toolCalls: [ToolCallContent] = []
        var stopReason: StopReason = .stop
        var usage = UsageStats()

        let llmMessages = context.messages
        let toolDefinitions = config.tools.map(\.definition)

        for try await event in config.llm.stream(
            model: config.model,
            systemPrompt: context.systemPrompt,
            messages: llmMessages,
            tools: toolDefinitions
        ) {
            try Task.checkCancellation()

            switch event {
            case let .textDelta(delta):
                text += delta
                continuation.yield(.textDelta(delta))
            case let .thinkingDelta(delta):
                continuation.yield(.thinkingDelta(delta))
            case let .toolCall(call):
                toolCalls.append(call)
            case let .completed(reason, stats):
                stopReason = reason
                usage = stats
            }
        }

        return AssistantMessage(
            text: text,
            toolCalls: toolCalls,
            provider: config.model.provider,
            modelID: config.model.modelID,
            stopReason: stopReason,
            usage: usage
        )
    }

    private func executeToolCalls(
        _ toolCalls: [ToolCallContent],
        context: AgentContext,
        config: AgentLoopConfig,
        continuation: AsyncStream<AgentEvent>.Continuation,
        messageSink: inout [AgentMessage]
    ) async throws {
        let registry = Dictionary(uniqueKeysWithValues: config.tools.map { ($0.name, $0) })
        let toolContext = ToolContext(workingDirectory: context.workingDirectory)

        let runSingle: (ToolCallContent) async throws -> ToolResultMessage = { call in
            continuation.yield(.toolExecutionStart(id: call.id, name: call.name, arguments: call.arguments))

            if let beforeToolCall = config.beforeToolCall {
                let decision = await beforeToolCall(call.name, call.arguments)
                if decision.block {
                    let reason = decision.reason ?? "blocked by policy"
                    let result = ToolResult(content: reason, isError: true)
                    continuation.yield(.toolExecutionEnd(id: call.id, name: call.name, result: result))
                    return ToolResultMessage(
                        toolCallID: call.id,
                        toolName: call.name,
                        content: reason,
                        isError: true
                    )
                }
            }

            guard let tool = registry[call.name] else {
                throw AgentError.toolNotFound(call.name)
            }

            do {
                let result = try await tool.execute(
                    id: call.id,
                    arguments: call.arguments,
                    context: toolContext,
                    onUpdate: { progress in
                        continuation.yield(.toolExecutionUpdate(id: call.id, message: progress.message))
                    }
                )
                continuation.yield(.toolExecutionEnd(id: call.id, name: call.name, result: result))
                return ToolResultMessage(
                    toolCallID: call.id,
                    toolName: call.name,
                    content: result.content,
                    isError: result.isError
                )
            } catch {
                let result = ToolResult(content: error.localizedDescription, isError: true)
                continuation.yield(.toolExecutionEnd(id: call.id, name: call.name, result: result))
                return ToolResultMessage(
                    toolCallID: call.id,
                    toolName: call.name,
                    content: error.localizedDescription,
                    isError: true
                )
            }
        }

        let toolResults: [ToolResultMessage]
        switch config.toolExecution {
        case .parallel, .sequential:
            var results: [ToolResultMessage] = []
            for call in toolCalls {
                results.append(try await runSingle(call))
            }
            toolResults = results
        }

        try appendToolResults(toolResults, to: &messageSink, continuation: continuation)
    }

    private func appendToolResults(
        _ results: [ToolResultMessage],
        to messageSink: inout [AgentMessage],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) throws {
        for result in results {
            let message = AgentMessage.toolResult(result)
            continuation.yield(.messageStart(message))
            messageSink.append(message)
            continuation.yield(.messageEnd(message))
        }
    }
}
