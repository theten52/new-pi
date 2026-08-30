import Foundation

/// High-level facade used by the NewPi macOS app and CLI.
public actor AgentSession {
    public private(set) var context: AgentContext
    public private(set) var config: AgentLoopConfig
    private let loop = AgentLoop()
    private let approvalGate = ToolApprovalGate()
    private let approvalTracker = ToolApprovalTracker()
    private var runTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var steeringQueue: [AgentMessage] = []
    private var persistenceFileURL: URL?
    private var persistenceHeader: SessionHeader?
    private var persistenceContext: SessionContext?
    private var persistenceLeafID: String?
    private var jsonlStore = JSONLSessionStore()
    /// 当前未落盘的 assistant 流式文本（用于生成途中被中断时保留部分输出）。
    private var inFlightText = ""

    public init(context: AgentContext, config: AgentLoopConfig) {
        self.context = context
        var configured = config
        configured.requestToolApproval = { [approvalGate] request in
            await approvalGate.wait(for: request)
        }
        configured.toolApprovalTracker = approvalTracker
        let approvalPolicy = ApprovalPolicyStore().load()
        configured.dangerEvaluator = DangerEvaluator(
            policy: approvalPolicy,
            llmSupplementEnabled: config.dangerEvaluator?.llmSupplementEnabled ?? approvalPolicy.llmSupplementEnabled,
            llmAssessor: config.dangerEvaluator?.llmAssessor
        )
        configured.dangerCache = config.dangerCache ?? DangerAssessmentCache()
        configured.auditLogger = config.auditLogger ?? ToolApprovalAuditLogger()
        self.config = configured
    }

    public func events() -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func prompt(_ text: String) {
        prompt(.user(text))
    }

    public func prompt(_ message: AgentMessage) {
        runTask?.cancel()
        let promptSummary: String = switch message {
        case let .user(user):
            "user: \(NewPiLogFormat.truncate(user.content, maxLength: 500))"
        case let .assistant(assistant):
            "assistant: \(assistant.toolCalls.count) tool calls"
        case let .toolResult(result):
            "toolResult: \(result.toolName)"
        case let .compactionSummary(summary):
            "compactionSummary: \(summary.count) chars"
        }
        NewPiLogger.info(
            category: "agent-session",
            message: "Prompt submitted",
            details: """
            \(promptSummary)
            cwd=\(context.workingDirectory.path)
            tools=\(NewPiLogFormat.describeToolRegistry(config.tools))
            """
        )
        runTask = Task {
            // 先清掉上一个 run 可能仍在挂起的审批：审批 wait 不响应任务取消，
            // 若不清理，用户之后点"允许"会让已取消的旧 run 复活并真正执行工具。
            // 在新 runTask 内、事件循环开始前执行，保证不会误清本次 run 的请求。
            await approvalGate.cancelAll()
            let steeringProvider: (@Sendable () async -> AgentMessage?)? = { [weak self] in
                guard let self else { return nil }
                return await self.dequeueSteering()
            }

            for await event in loop.run(
                prompt: message,
                context: context,
                config: config,
                steeringProvider: steeringProvider
            ) {
                if case let .textDelta(delta) = event {
                    inFlightText += delta
                }
                if case let .contextSnapshot(snapshot) = event {
                    // 快照代表已提交，未完成的流式文本从此重置。
                    inFlightText = ""
                    context = snapshot
                    // 诊断：persistIfNeeded 在 actor 上同步全量重写 JSONL，
                    // 若变慢会阻塞后续事件向 UI 的投递（疑似回复慢的根因之一）。
                    let persistStart = Date()
                    persistIfNeeded()
                    let persistElapsed = Date().timeIntervalSince(persistStart)
                    if persistElapsed > 0.05 {
                        NewPiLogger.info(
                            category: "agent-session",
                            message: "Slow session persist",
                            details: "elapsed=\(String(format: "%.2f", persistElapsed))s messages=\(snapshot.messages.count)"
                        )
                    }
                }
                // 诊断：事件从 loop 到 broadcast 的处理耗时（>0.2s 记日志）。
                let broadcastStart = Date()
                broadcast(event)
                let broadcastElapsed = Date().timeIntervalSince(broadcastStart)
                if broadcastElapsed > 0.2 {
                    NewPiLogger.info(
                        category: "agent-session",
                        message: "Slow event broadcast",
                        details: "elapsed=\(String(format: "%.2f", broadcastElapsed))s"
                    )
                }
            }
        }
    }

    public func steer(_ text: String) {
        steeringQueue.append(.user(text))
    }

    public func respondToToolApproval(
        requestID: String,
        approved: Bool,
        scope: ApprovalScope = .once
    ) async {
        let decision = ApprovalDecision(approved: approved, scope: scope)
        let response = await approvalGate.respond(requestID: requestID, decision: decision)
        NewPiLogger.info(
            category: "agent-session",
            message: "Tool approval response forwarded",
            details: "requestID=\(requestID) approved=\(approved) scope=\(scope) tool=\(response?.toolName ?? "unknown")"
        )
        if let response, response.decision.approved {
            // 记录授权（high 级别不写入 session/forever，仅放行本次）。
            await approvalTracker.record(
                scope: response.decision.scope,
                toolName: response.toolName,
                fingerprint: response.fingerprint,
                dangerLevel: response.dangerLevel
            )
        }
    }

    public func abort() {
        NewPiLogger.info(category: "agent-session", message: "Agent abort requested")
        runTask?.cancel()
        Task {
            await approvalGate.cancelAll()
        }
        broadcast(.error(.aborted))
        broadcast(.agentEnd)
    }

    /// 停止仍在运行的 agent run，并等待它停止后返回。
    ///
    /// 用于 UI 切换到另一个 session 时：若不先停止上一个 session，它会在后台
    /// 继续流式输出（事件无处投递，内容丢失），且 context 不会及时落盘，
    /// 导致"切回旧 session 看不到刚才的输出"。此方法取消 runTask 等待其退出，
    /// 把尚未落盘的流式文本保留为一条 aborted 消息并写盘，再清掉续体与审批等待。
    public func shutdown() async {
        NewPiLogger.info(category: "agent-session", message: "Agent session shutdown requested")
        runTask?.cancel()
        if let task = runTask {
            await task.value
        }
        await approvalGate.cancelAll()
        // runTask 被取消时会丢弃缓冲的最终 contextSnapshot，因此把仍在流式、尚未
        // 提交的部分文本作为一条 aborted 的 assistant 消息写回 context，再落盘，
        // 确保"生成途中切走，回来还能看到已输出的部分内容"。
        if !inFlightText.isEmpty {
            context.messages.append(.assistant(AssistantMessage(
                text: inFlightText,
                reasoningContent: "",
                provider: config.model.provider,
                modelID: config.model.modelID,
                stopReason: .aborted
            )))
            inFlightText = ""
        }
        persistIfNeeded()
        eventContinuations.removeAll()
    }

    public func updateConfig(_ config: AgentLoopConfig) {
        var configured = config
        configured.requestToolApproval = { [approvalGate] request in
            await approvalGate.wait(for: request)
        }
        configured.toolApprovalTracker = approvalTracker
        let approvalPolicy = ApprovalPolicyStore().load()
        configured.dangerEvaluator = DangerEvaluator(
            policy: approvalPolicy,
            llmSupplementEnabled: config.dangerEvaluator?.llmSupplementEnabled ?? approvalPolicy.llmSupplementEnabled,
            llmAssessor: config.dangerEvaluator?.llmAssessor
        )
        configured.dangerCache = config.dangerCache ?? DangerAssessmentCache()
        configured.auditLogger = config.auditLogger ?? ToolApprovalAuditLogger()
        self.config = configured
        NewPiLogger.info(
            category: "agent-session",
            message: "Session config updated",
            details: """
            model=\(config.model.provider)/\(config.model.modelID)
            tools=\(NewPiLogFormat.describeToolRegistry(config.tools))
            """
        )
    }

    public func attachPersistence(fileURL: URL, header: SessionHeader) {
        persistenceFileURL = fileURL
        persistenceHeader = header
        if let loaded = try? jsonlStore.load(from: fileURL) {
            persistenceContext = loaded
            persistenceLeafID = loaded.leafID
        } else {
            persistenceContext = SessionContext(header: header)
            persistenceLeafID = nil
        }
    }

    public var attachedSessionHeader: SessionHeader? {
        persistenceHeader
    }

    public func updateSessionLabel(_ label: String) {
        guard var persisted = persistenceContext, let fileURL = persistenceFileURL else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        persisted.header.label = trimmed
        persistenceHeader = persisted.header
        persistenceContext = persisted
        try? jsonlStore.save(persisted, to: fileURL)
    }

    /// 手动重命名会话时用：允许把 label 设为 nil（留空 = 重置为默认显示名），
    /// 同时更新内存态 `persistenceContext`/`persistenceHeader` 并落盘。
    /// 关键：若不更新内存态，后续 `persistIfNeeded()` 会用内存里的旧 header
    /// 覆盖掉刚写进磁盘的新 label，导致重命名结果在下次消息落盘时丢失。
    public func setSessionLabel(_ label: String?) {
        guard var persisted = persistenceContext, let fileURL = persistenceFileURL else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel: String? = (trimmed?.isEmpty == false) ? trimmed : nil
        persisted.header.label = finalLabel
        persistenceHeader = persisted.header
        persistenceContext = persisted
        try? jsonlStore.save(persisted, to: fileURL)
    }

    /// 更新会话 header（如会话内切换 provider/model）并**立即落盘**。
    /// 注意不能用 `attachPersistence` 代替：它只更新内存中的 header，且会从磁盘重载
    /// 带旧 header 的 context——下次 persistIfNeeded 会把 header 覆盖回旧值，
    /// 导致「切换 provider 后未发消息就退出 App」时选择丢失。
    public func updateSessionHeader(_ header: SessionHeader) {
        persistenceHeader = header
        guard var persisted = persistenceContext, let fileURL = persistenceFileURL else { return }
        persisted.header = header
        persistenceContext = persisted
        do {
            try jsonlStore.save(persisted, to: fileURL)
        } catch {
            NewPiLogger.error(
                category: "agent",
                message: "Failed to persist session header",
                details: error.localizedDescription
            )
        }
    }

    public var activeBranchLeafID: String? {
        persistenceLeafID
    }

    public func fork(atMessageIndex index: Int) throws {
        guard index >= 0, index < context.messages.count else {
            throw AgentError.invalidState("Invalid fork index: \(index)")
        }

        context.messages = Array(context.messages.prefix(index + 1))

        guard var persisted = persistenceContext else { return }
        let entries = SessionManager.messageEntries(from: persisted, leafID: persistenceLeafID)
        guard index < entries.count else {
            throw AgentError.invalidState("Session entry not found for message index \(index)")
        }

        let entryID = entries[index].0.id
        persisted = try SessionManager.forkContext(persisted, at: entryID)
        persistenceContext = persisted
        persistenceLeafID = entryID
        persistIfNeeded()
    }

    public func branchEntryIDs() -> [String] {
        guard let persisted = persistenceContext else { return [] }
        return SessionManager.messageEntries(from: persisted, leafID: persistenceLeafID).map(\.0.id)
    }

    public func branchPointCount() -> Int {
        guard let persisted = persistenceContext else { return 0 }
        return SessionManager.branchPointCount(in: persisted)
    }

    private func persistIfNeeded() {
        guard let fileURL = persistenceFileURL, let header = persistenceHeader else { return }

        var persisted = persistenceContext ?? SessionContext(header: header)
        var leafID = persistenceLeafID

        SessionManager.syncMessages(context.messages, into: &persisted, leafID: &leafID)

        persistenceContext = persisted
        persistenceLeafID = leafID
        persistenceHeader = persisted.header
        try? jsonlStore.save(persisted, to: fileURL)
    }

    private func dequeueSteering() -> AgentMessage? {
        guard !steeringQueue.isEmpty else { return nil }
        return steeringQueue.removeFirst()
    }

    private func broadcast(_ event: AgentEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}

public enum AgentSessionFactory {
    public static func codingTools(
        workingDirectory: URL,
        llm: any LLMProvider,
        model: ModelConfig,
        additionalTools: [any AgentTool] = []
    ) -> [any AgentTool] {
        var tools = BuiltInTools.codingTools(for: workingDirectory)
        tools.append(SubAgentTool(llm: llm, model: model))
        tools.append(contentsOf: additionalTools)
        return tools
    }

    public static func codingSession(
        workingDirectory: URL,
        llm: any LLMProvider,
        model: ModelConfig,
        toolPolicy: ToolPolicyRules = .codingAgentDefault,
        restoredMessages: [AgentMessage] = [],
        additionalTools: [any AgentTool] = []
    ) -> AgentSession {
        let tools = codingTools(
            workingDirectory: workingDirectory,
            llm: llm,
            model: model,
            additionalTools: additionalTools
        )
        let approvalPolicy = ApprovalPolicyStore().load()
        let config = AgentLoopConfig(
            model: model,
            llm: llm,
            tools: tools,
            toolPolicy: toolPolicy,
            dangerEvaluator: DangerEvaluator(
                policy: approvalPolicy,
                llmSupplementEnabled: approvalPolicy.llmSupplementEnabled
            ),
            dangerCache: DangerAssessmentCache(),
            auditLogger: ToolApprovalAuditLogger()
        )
        let context = AgentContext(
            systemPrompt: SystemPromptComposer.compose(for: workingDirectory).text,
            messages: restoredMessages,
            workingDirectory: workingDirectory
        )
        logSessionCreated(workingDirectory: workingDirectory, model: model, tools: tools)
        return AgentSession(context: context, config: config)
    }
}

extension AgentSessionFactory {
    public static func logSessionCreated(
        workingDirectory: URL,
        model: ModelConfig,
        tools: [any AgentTool]
    ) {
        NewPiLogger.info(
            category: "agent-session",
            message: "Coding session created",
            details: """
            cwd=\(workingDirectory.path)
            model=\(model.provider)/\(model.modelID)
            tools=\(NewPiLogFormat.describeToolRegistry(tools))
            """
        )
    }
}
