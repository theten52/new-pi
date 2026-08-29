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
                // 注意：必须在 do 块外声明，否则 catch 分支只能看到 run 开始前的
                // 初始快照，错误路径会把已提交的会话整体回滚。
                var context = context
                do {
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
                    // 增量持久化：用户消息一到就落盘，避免生成途中切换 session 时
                    // 连已提交的用户输入都丢失（后续每轮完成也会再发一次快照）。
                    continuation.yield(.contextSnapshot(context))

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
                        // 每轮完成即落盘（增量持久化），保证任何时刻切走都有已提交内容。
                        continuation.yield(.contextSnapshot(context))

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
        var reasoningSignature = ""
        var toolCalls: [ToolCallContent] = []
        var stopReason: StopReason = .stop
        var usage = UsageStats()
        // 诊断：记录最后一次 text/thinking 增量的时刻，区分「服务端静默尾段」
        // 与「收尾 reasoning 占时间」（回复结束后状态迟迟不变的根因定位）。
        var lastTextDeltaAt: Date?
        var lastThinkingDeltaAt: Date?

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
                lastTextDeltaAt = Date()
                continuation.yield(.textDelta(delta))
            case let .thinkingDelta(delta):
                reasoningContent += delta
                lastThinkingDeltaAt = Date()
                continuation.yield(.thinkingDelta(delta))
            case let .thinkingSignature(signature):
                reasoningSignature += signature
            case let .toolCall(call):
                toolCalls.append(call)
            case let .completed(reason, stats):
                stopReason = reason
                usage = stats
            }
        }

        // 诊断：流结束时的尾段分析。textTail 大 = 服务端发完正文后静默；
        // thinking 区间长且贴近结束 = 收尾 reasoning 占用时间。
        let streamEndAt = Date()
        let textTail = lastTextDeltaAt.map { streamEndAt.timeIntervalSince($0) } ?? -1
        let thinkTail = lastThinkingDeltaAt.map { streamEndAt.timeIntervalSince($0) } ?? -1
        if textTail > 1 || thinkTail > 1 {
            NewPiLogger.info(
                category: "agent-loop",
                message: "Stream tail analysis",
                details: "textTail=\(String(format: "%.1f", textTail))s thinkTail=\(String(format: "%.1f", thinkTail))s textLen=\(text.count) reasoningLen=\(reasoningContent.count)"
            )
        }

        return AssistantMessage(
            text: text,
            reasoningContent: reasoningContent,
            reasoningSignature: reasoningSignature,
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
        let toolContext = ToolContext(
            workingDirectory: context.workingDirectory,
            toolPolicy: config.toolPolicy,
            beforeToolCall: config.beforeToolCall,
            requestToolApproval: config.requestToolApproval,
            toolApprovalTracker: config.toolApprovalTracker,
            dangerEvaluator: config.dangerEvaluator,
            dangerCache: config.dangerCache
        )

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

            let requiresApproval = config.toolPolicy.requiresApproval(toolName: call.name)
            let fingerprint = ToolApprovalFingerprint.make(arguments: call.arguments)

            // 危险评估（缓存优先）。
            let dangerEvaluator = config.dangerEvaluator ?? DangerEvaluator()
            let assessment = await dangerEvaluator.evaluate(
                toolName: call.name,
                arguments: call.arguments,
                cache: config.dangerCache
            )

            let alreadyApproved: Bool
            if requiresApproval, let tracker = config.toolApprovalTracker {
                alreadyApproved = await tracker.isAuthorized(
                    toolName: call.name,
                    fingerprint: fingerprint,
                    dangerLevel: assessment.level
                )
            } else {
                alreadyApproved = false
            }

            if requiresApproval && !alreadyApproved {
                let request = ToolApprovalRequest(
                    id: call.id,
                    toolName: call.name,
                    arguments: call.arguments,
                    summary: ToolApprovalSummary.make(toolName: call.name, arguments: call.arguments),
                    dangerLevel: assessment.level,
                    dangerReason: assessment.reason,
                    parametersFingerprint: fingerprint
                )
                continuation.yield(.toolApprovalRequired(request))

                NewPiLogger.info(
                    category: "tool-approval",
                    message: "Waiting for user approval",
                    details: """
                    requestID=\(request.id)
                    tool=\(request.toolName)
                    summary=\(request.summary)
                    dangerLevel=\(assessment.level.rawValue)
                    dangerReason=\(assessment.reason ?? "none")
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

                let decision = await requestToolApproval(request)
                NewPiLogger.info(
                    category: "tool-approval",
                    message: decision.approved ? "Tool approved" : "Tool denied",
                    details: "requestID=\(request.id) tool=\(request.toolName) scope=\(decision.scope)"
                )
                if !decision.approved {
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
                // 记录授权（high 级别不写入永久/会话记录，仅放行本次）。
                if let tracker = config.toolApprovalTracker {
                    await tracker.record(
                        scope: decision.scope,
                        toolName: call.name,
                        fingerprint: fingerprint,
                        dangerLevel: assessment.level
                    )
                }
            }

            // 审批等待期间任务可能已被取消：执行有副作用的工具前最后检查一次。
            try Task.checkCancellation()

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
