import Foundation

public struct AgentLoop: Sendable {
    private let compactionService = CompactionService()

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
                    NewPiLogger.info(
                        category: "agent-loop",
                        message: "Agent run started",
                        details: """
                        Working directory: \(context.workingDirectory.path)
                        Registered tools: \(NewPiLogFormat.describeToolRegistry(config.tools))
                        Message count: \(context.messages.count)
                        Model: \(config.model.provider)/\(config.model.modelID)
                        """
                    )
                    continuation.yield(.agentStart)

                    try appendMessage(prompt, to: &context, continuation: continuation)

                    var shouldContinue = true
                    var turnIndex = 0
                    while shouldContinue {
                        try Task.checkCancellation()
                        turnIndex += 1
                        if turnIndex > config.maxTurns {
                            NewPiLogger.error(
                                category: "agent-loop",
                                message: "Max agent turns exceeded",
                                details: "limit=\(config.maxTurns)"
                            )
                            throw AgentError.invalidState(
                                "Agent stopped after \(config.maxTurns) turns to prevent an infinite tool loop."
                            )
                        }
                        NewPiLogger.debug(
                            category: "agent-loop",
                            message: "Turn started",
                            details: "Turn #\(turnIndex), messages=\(context.messages.count)"
                        )
                        continuation.yield(.turnStart)

                        try await compactionService.compactIfNeeded(
                            context: &context,
                            config: config,
                            continuation: continuation
                        )

                        AgentMessageHistoryRepair.repairOrphanedToolCalls(in: &context.messages)

                        let assistant = try await streamAssistant(
                            context: context,
                            config: config,
                            continuation: continuation
                        )
                        try appendMessage(.assistant(assistant), to: &context, continuation: continuation)

                        NewPiLogger.debug(
                            category: "agent-loop",
                            message: "Assistant turn completed",
                            details: """
                            stopReason=\(assistant.stopReason.rawValue)
                            textLength=\(assistant.text.count)
                            reasoningLength=\(assistant.reasoningContent.count)
                            toolCalls=\(assistant.toolCalls.count)
                            \(assistant.toolCalls.map { "- \($0.name) (\($0.id))" }.joined(separator: "\n"))
                            """
                        )

                        if !assistant.toolCalls.isEmpty {
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

                    NewPiLogger.info(category: "agent-loop", message: "Agent run finished", details: "Turns=\(turnIndex)")
                    continuation.yield(.contextSnapshot(context))
                    continuation.yield(.agentEnd)
                    continuation.finish()
                } catch is CancellationError {
                    NewPiLogger.info(category: "agent-loop", message: "Agent run cancelled")
                    continuation.yield(.error(.aborted))
                    continuation.yield(.contextSnapshot(context))
                    continuation.yield(.agentEnd)
                    continuation.finish()
                } catch let error as AgentError {
                    NewPiLogger.error(
                        category: "agent-loop",
                        message: "Agent run failed",
                        details: error.localizedDescription
                    )
                    continuation.yield(.error(error))
                    continuation.yield(.contextSnapshot(context))
                    continuation.yield(.agentEnd)
                    continuation.finish()
                } catch {
                    NewPiLogger.error(
                        category: "agent-loop",
                        message: "Agent run failed with unexpected error",
                        details: error.localizedDescription
                    )
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
        var reasoningContent = ""
        var toolCalls: [ToolCallContent] = []
        var stopReason: StopReason = .stop
        var usage = UsageStats()

        let llmMessages = context.messages
        let toolDefinitions = config.tools.map(\.definition)

        NewPiLogger.debug(
            category: "agent-loop",
            message: "Streaming assistant response",
            details: """
            messages=\(llmMessages.count)
            tools=\(toolDefinitions.count)
            """
        )

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
                reasoningContent += delta
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
            reasoningContent: reasoningContent,
            toolCalls: toolCalls,
            provider: config.model.provider,
            modelID: config.model.modelID,
            stopReason: toolCalls.isEmpty ? stopReason : .toolUse,
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
        var registry: [String: any AgentTool] = [:]
        for tool in config.tools {
            registry[tool.name] = tool
        }
        let toolContext = ToolContext(workingDirectory: context.workingDirectory)

        NewPiLogger.info(
            category: "tool",
            message: "Executing tool batch",
            details: """
            count=\(toolCalls.count)
            cwd=\(context.workingDirectory.path)
            registry=[\(registry.keys.sorted().joined(separator: ", "))]
            \(toolCalls.map { NewPiLogFormat.describeToolCall($0) }.joined(separator: "\n---\n"))
            """
        )

        let runSingle: (ToolCallContent) async throws -> ToolResultMessage = { call in
            NewPiLogger.debug(
                category: "tool",
                message: "Tool call received",
                details: NewPiLogFormat.describeToolCall(call)
            )

            if config.toolPolicy.requiresApproval(toolName: call.name) {
                let request = ToolApprovalRequest(
                    id: call.id,
                    toolName: call.name,
                    arguments: call.arguments,
                    summary: ToolApprovalSummary.make(toolName: call.name, arguments: call.arguments)
                )
                continuation.yield(.toolApprovalRequired(request))

                NewPiLogger.info(
                    category: "tool-approval",
                    message: "Waiting for user approval",
                    details: """
                    requestID=\(request.id)
                    tool=\(request.toolName)
                    summary=\(request.summary)
                    """
                )

                guard let requestToolApproval = config.requestToolApproval else {
                    NewPiLogger.error(
                        category: "tool-approval",
                        message: "Approval handler missing",
                        details: "tool=\(call.name) requestID=\(call.id)"
                    )
                    let reason = "Tool execution denied: approval handler not configured"
                    let result = ToolResult(content: reason, isError: true)
                    continuation.yield(.toolExecutionEnd(id: call.id, name: call.name, result: result))
                    return ToolResultMessage(
                        toolCallID: call.id,
                        toolName: call.name,
                        content: reason,
                        isError: true
                    )
                }

                let approved = await requestToolApproval(request)
                NewPiLogger.info(
                    category: "tool-approval",
                    message: approved ? "Tool approved" : "Tool denied",
                    details: "requestID=\(request.id) tool=\(request.toolName)"
                )
                if !approved {
                    let reason = "Tool execution denied by policy"
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
                let reason = "Tool not found: \(call.name)"
                NewPiLogger.error(
                    category: "tool",
                    message: "Tool not found in registry",
                    details: """
                    requested=\(call.name)
                    available=[\(registry.keys.sorted().joined(separator: ", "))]
                    """
                )
                let result = ToolResult(content: reason, isError: true)
                continuation.yield(.toolExecutionEnd(id: call.id, name: call.name, result: result))
                return ToolResultMessage(
                    toolCallID: call.id,
                    toolName: call.name,
                    content: reason,
                    isError: true
                )
            }

            do {
                let startedAt = Date()
                let result = try await tool.execute(
                    id: call.id,
                    arguments: call.arguments,
                    context: toolContext,
                    onUpdate: { progress in
                        continuation.yield(.toolExecutionUpdate(id: call.id, message: progress.message))
                    }
                )
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                NewPiLogger.info(
                    category: "tool",
                    message: result.isError ? "Tool finished with error" : "Tool finished",
                    details: """
                    tool=\(call.name)
                    id=\(call.id)
                    elapsedMs=\(elapsedMs)
                    output=\(NewPiLogFormat.truncate(result.content, maxLength: 4000))
                    """
                )
                continuation.yield(.toolExecutionEnd(id: call.id, name: call.name, result: result))
                return ToolResultMessage(
                    toolCallID: call.id,
                    toolName: call.name,
                    content: result.content,
                    isError: result.isError
                )
            } catch {
                NewPiLogger.error(
                    category: "tool",
                    message: "Tool threw error",
                    details: """
                    tool=\(call.name)
                    id=\(call.id)
                    error=\(error.localizedDescription)
                    """
                )
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
