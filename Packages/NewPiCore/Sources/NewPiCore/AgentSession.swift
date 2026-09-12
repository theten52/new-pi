import Foundation

/// High-level facade used by the NewPi macOS app and CLI.
public actor AgentSession {
    public private(set) var context: AgentContext
    public private(set) var config: AgentLoopConfig
    private let loop = AgentLoop()
    private let approvalGate = ToolApprovalGate()
    private let approvalTracker = ToolApprovalTracker()
    private var runTask: Task<Void, Never>?
    /// 错误与未提交输出归本次运行；首个快照出现前不借用上一轮用户条目。
    private final class RunErrorState {
        let model: ModelConfig
        var anchorEntryID: String?
        var pending: [SessionTranscriptError] = []
        var seenMessages: Set<String> = []
        var text = ""
        var thinking = ""
        var completedAssistant: AssistantMessage?
        var interruptedAssistant: AssistantMessage?
        var stopped = false
        var failed = false
        var acceptedUser = false
        var retryErrorID: UUID?

        init(model: ModelConfig) { self.model = model }
    }
    private var runErrorState: RunErrorState?
    /// PROBE（BACKLOG-STALL）：本 run 已 broadcast 的 textDelta 计数（见 broadcast 前探针）。
    private var probeTextCount = 0
    private var eventContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var steeringQueue: [AgentMessage] = []
    private var persistenceFileURL: URL?
    private var persistenceHeader: SessionHeader?
    private var persistenceContext: SessionContext?
    private var persistenceLeafID: String?
    private var jsonlStore = JSONLSessionStore()

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
        // 项目根内文件操作免审批：根取本会话 workingDirectory，开关走持久化策略。
        configured.projectScope = config.projectScope ?? ProjectScopePolicy(
            root: context.workingDirectory,
            isEnabled: approvalPolicy.projectScopeAutoApprove
        )
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
        startRun(message)
    }

    /// 原子领取最新失败锚点。拒绝运行中、旧轮次、取消及结果不完整的工具阶段。
    /// 不 fork、不删历史、不隐式追加 Continue 用户消息。
    public func retry(errorID: UUID) throws {
        guard runTask == nil else { throw AgentError.invalidState("会话仍在运行，不能重复重试。") }
        guard let record = transcriptErrors().last, record.error.id == errorID,
              record.error.retryState == "available", retryAnchorIsValid(record) else {
            throw AgentError.invalidState("此错误已过期或不处于安全的模型请求边界，不能重试。")
        }
        guard updateTranscriptError(errorID, retryState: "retrying") else {
            throw AgentError.invalidState("无法保存重试状态，已停止重试；请检查会话存储。")
        }
        startRun(nil, retryRecord: record)
    }

    private func startRun(_ message: AgentMessage?, retryRecord: AnchoredSessionTranscriptError? = nil) {
        RequestLatencyContext.current?.mark(.promptReceived)
        if let previous = runErrorState, !previous.stopped {
            previous.stopped = true
            preserveReceivedAssistant(previous, reason: .aborted)
        }
        runTask?.cancel()
        let errorState = RunErrorState(model: config.model)
        errorState.retryErrorID = retryRecord?.error.id
        errorState.anchorEntryID = retryRecord?.entryID
        if case .user = message { errorState.acceptedUser = true }
        if retryRecord != nil { errorState.acceptedUser = true }
        runErrorState = errorState
        if let message {
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
        }
        runTask = Task {
            defer {
                if runErrorState === errorState {
                    runErrorState = nil
                    runTask = nil
                }
            }
            // 先清掉上一个 run 可能仍在挂起的审批：审批 wait 不响应任务取消，
            // 若不清理，用户之后点"允许"会让已取消的旧 run 复活并真正执行工具。
            // 在新 runTask 内、事件循环开始前执行，保证不会误清本次 run 的请求。
            await approvalGate.cancelAll()
            guard runErrorState === errorState, !errorState.stopped, !Task.isCancelled else { return }
            let steeringProvider: (@Sendable () async -> AgentMessage?)? = { [weak self] in
                guard let self else { return nil }
                return await self.dequeueSteering()
            }

            let events = message.map {
                loop.run(prompt: $0, context: context, config: config, steeringProvider: steeringProvider)
            } ?? loop.resume(context: context, config: config, steeringProvider: steeringProvider)
            for await event in events {
                // 取消/被替换的 run 不得再提交旧快照或向下一轮投递迟到事件。
                guard runErrorState === errorState, !errorState.stopped else { break }
                var event = event
                if case let .textDelta(delta) = event {
                    errorState.text += delta
                }
                if case let .thinkingDelta(delta) = event {
                    errorState.thinking += delta
                }
                if case let .messageEnd(.assistant(assistant)) = event {
                    errorState.completedAssistant = assistant
                }
                if case let .error(error) = event {
                    errorState.failed = true
                    preserveReceivedAssistant(errorState, reason: error == .aborted ? .aborted : .error)
                }
                if case let .contextSnapshot(snapshot) = event {
                    context = snapshot
                    // 失败快照不含未完成的流式结果；恢复已定型的部分回答，不能用旧快照擦掉它。
                    if let partial = errorState.interruptedAssistant {
                        if context.messages.last != .assistant(partial) {
                            context.messages.append(.assistant(partial))
                        }
                        event = .contextSnapshot(context)
                    }
                    errorState.text = ""
                    errorState.thinking = ""
                    errorState.completedAssistant = nil
                    // 诊断：persistIfNeeded 在 actor 上同步全量重写 JSONL，
                    // 若变慢会阻塞后续事件向 UI 的投递（疑似回复慢的根因之一）。
                    let persistStart = Date()
                    persistIfNeeded()
                    if errorState.acceptedUser, let persisted = persistenceContext {
                        errorState.anchorEntryID = persisted.branch(from: persistenceLeafID).last { entry in
                            if case .user = entry.message { return true }
                            return false
                        }?.id
                        persistPendingTranscriptErrors(errorState)
                    }
                    let persistElapsed = Date().timeIntervalSince(persistStart)
                    if persistElapsed > 0.05 {
                        NewPiLogger.info(
                            category: "agent-session",
                            message: "Slow session persist",
                            details: "elapsed=\(String(format: "%.2f", persistElapsed))s messages=\(snapshot.messages.count)"
                        )
                    }
                }
                // PROBE（BACKLOG-STALL / STALL-VERIFY 定位）：事件到达 broadcast 的时刻。
                // textDelta 每 100 个一条（与 UI 消费端 consumed 探针 cadence 对齐，
                // 同序号两端时间差 = 投递/调度延迟）；边界事件全记。
                switch event {
                case .agentStart:
                    probeTextCount = 0
                    NewPiLogger.info(category: "agent-session", message: "PROBE broadcast", details: "agentStart")
                case .textDelta:
                    probeTextCount += 1
                    if probeTextCount % 100 == 0 {
                        NewPiLogger.info(category: "agent-session", message: "STALL-VERIFY bcast", details: "text#\(probeTextCount)")
                    }
                case .messageStart, .messageEnd, .agentEnd, .error:
                    NewPiLogger.info(category: "agent-session", message: "PROBE broadcast", details: "\(event.diagnosticName)")
                default:
                    break
                }
                // 诊断：事件从 loop 到 broadcast 的处理耗时（>0.2s 记日志）。
                if case .agentEnd = event {
                    if let id = errorState.retryErrorID {
                        let completed: Bool
                        if case let .assistant(assistant) = context.messages.last {
                            completed = assistant.stopReason == .stop && assistant.toolCalls.isEmpty
                        } else { completed = false }
                        updateTranscriptError(id, retryState: !errorState.failed && completed ? "recovered" : "unavailable")
                    }
                    // 结束事件可见时即释放领取锁；旧任务的 defer 不得清掉新运行。
                    errorState.stopped = true
                    runTask = nil
                    runErrorState = nil
                }
                let broadcastStart = Date()
                broadcast(event, errorState: errorState)
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
        guard let state = runErrorState, !state.stopped else { return }
        state.stopped = true
        state.failed = true
        runTask?.cancel()
        // 先定型保存已交付给 UI 的内容，再发错误/结束事件；不依赖取消后的流继续被消费。
        preserveReceivedAssistant(state, reason: .aborted)
        Task {
            await approvalGate.cancelAll()
        }
        broadcast(.error(.aborted), errorState: state)
        if let id = state.retryErrorID { updateTranscriptError(id, retryState: "unavailable") }
        broadcast(.agentEnd, errorState: state)
    }

    /// 停止仍在运行的 agent run，并等待它停止后返回。
    ///
    /// 用于运行时淘汰、切项目等真正关闭 Session 的场景（普通热切换不调用）。
    /// 先保存已收到的正文/思考，再取消 runTask 等待其退出并清掉续体与审批等待。
    public func shutdown() async {
        NewPiLogger.info(category: "agent-session", message: "Agent session shutdown requested")
        if let state = runErrorState, !state.stopped {
            state.stopped = true
            preserveReceivedAssistant(state, reason: .aborted)
        }
        runTask?.cancel()
        if let task = runTask {
            await task.value
        }
        await approvalGate.cancelAll()
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
        // 与 init 同源：根取会话 workingDirectory，开关走持久化策略。
        configured.projectScope = config.projectScope ?? ProjectScopePolicy(
            root: context.workingDirectory,
            isEnabled: ApprovalPolicyStore().load().projectScopeAutoApprove
        )
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

    /// 冷恢复已解码的上下文直接复用，保留分支 leaf/条目身份，避免再次读取整个 JSONL。
    public func attachPersistence(fileURL: URL, context: SessionContext) {
        persistenceFileURL = fileURL
        persistenceHeader = context.header
        persistenceContext = context
        persistenceLeafID = context.leafID
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

    public func transcriptErrors() -> [AnchoredSessionTranscriptError] {
        guard let persisted = persistenceContext else { return [] }
        let records = SessionManager.transcriptErrors(from: persisted, leafID: persistenceLeafID)
        return records.map { record in
            var error = record.error
            if error.retryState == "available",
               (record.error.id != records.last?.error.id || !retryAnchorIsValid(record)) {
                error.retryState = "unavailable"
                error.errorTitle = "\(error.errorTitle ?? "请求失败")（上下文已变化，无法安全重试）"
            }
            // 冷恢复不能假称仍在重试，也不能自动重放可能已执行的工具。
            if error.retryState == "retrying", runErrorState?.retryErrorID != error.id {
                error.retryState = "unavailable"
                error.errorTitle = "重试已中断，无法安全继续"
            }
            return AnchoredSessionTranscriptError(entryID: record.entryID, error: error)
        }
    }

    private func retryAnchorIsValid(_ record: AnchoredSessionTranscriptError) -> Bool {
        guard record.error.retryLeafID == persistenceLeafID,
              let persisted = persistenceContext,
              let user = persisted.branch(from: persistenceLeafID).last(where: {
                  if case .user = $0.message { return true }; return false
              }), user.id == record.entryID,
              context.messages == SessionManager.messages(from: persisted, leafID: persistenceLeafID),
              context.messages.contains(where: { if case .user = $0 { return true }; return false }) else { return false }
        return hasCompleteToolResults
    }

    private var hasCompleteToolResults: Bool {
        var pending = Set<String>()
        for message in context.messages {
            switch message {
            case let .assistant(assistant):
                pending.formUnion(assistant.toolCalls.map(\.id))
            case let .toolResult(result): pending.remove(result.toolCallID)
            case .user, .compactionSummary:
                if !pending.isEmpty { return false }
            }
        }
        return pending.isEmpty
    }

    @discardableResult
    private func updateTranscriptError(_ id: UUID, retryState: String) -> Bool {
        guard var persisted = persistenceContext else { return false }
        for index in persisted.entries.indices {
            guard let errorIndex = persisted.entries[index].transcriptErrors?.firstIndex(where: { $0.id == id }) else { continue }
            persisted.entries[index].transcriptErrors?[errorIndex].retryState = retryState
        }
        persistenceContext = persisted
        guard let fileURL = persistenceFileURL else { return false }
        do {
            try jsonlStore.save(persisted, to: fileURL)
            return true
        } catch {
            NewPiLogger.error(category: "agent-session", message: "Failed to persist retry state", details: error.localizedDescription)
            return false
        }
    }

    /// 保存已消费的正文/思考。完整 messageEnd 优先，未完成输出没有可安全执行的工具调用或思考签名。
    /// 只在中断边界写盘；随后 shutdown、迟到快照或新 prompt 不会重复追加。
    private func preserveReceivedAssistant(_ state: RunErrorState, reason: StopReason) {
        let assistant: AssistantMessage
        if let completed = state.completedAssistant {
            assistant = completed
        } else {
            guard !state.text.isEmpty || !state.thinking.isEmpty else { return }
            assistant = AssistantMessage(
                text: state.text, reasoningContent: state.thinking,
                provider: state.model.provider, modelID: state.model.modelID,
                stopReason: reason
            )
        }
        state.text = ""
        state.thinking = ""
        state.completedAssistant = nil
        state.interruptedAssistant = assistant
        context.messages.append(.assistant(assistant))
        persistIfNeeded()
    }

    /// 在错误广播前落盘，由 actor 串行维护同一份上下文，避免 UI 另写 JSONL 被下一快照覆盖。
    /// 错误附于最近用户消息（或压缩摘要），不是额外的模型消息，也不会改变 leaf / 消息索引。
    private func persistPendingTranscriptErrors(_ state: RunErrorState) {
        guard !state.pending.isEmpty, let anchor = state.anchorEntryID,
              let fileURL = persistenceFileURL, var persisted = persistenceContext,
              let index = persisted.entries.firstIndex(where: { $0.id == anchor }) else { return }
        persisted.entries[index].transcriptErrors = (persisted.entries[index].transcriptErrors ?? [])
            + state.pending
        state.pending.removeAll()
        // 即使当前写入失败，后续快照/shutdown也会从这份内存元数据重试保存。
        persistenceContext = persisted
        do {
            try jsonlStore.save(persisted, to: fileURL)
        } catch {
            // 不能再次广播 error，否则存储失败会递归；UI 仍显示原始运行错误。
            NewPiLogger.error(category: "agent-session", message: "Failed to persist transcript error", details: error.localizedDescription)
        }
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

    private func broadcast(_ event: AgentEvent, errorState: RunErrorState? = nil) {
        if case let .error(error) = event, let state = errorState ?? runErrorState {
            // abort 的即时事件与循环取消收尾可能报告同一个错误；同一run只保存/展示一次。
            guard state.seenMessages.insert(error.localizedDescription).inserted else { return }
            let retryable: Bool
            if case .llmFailed = error {
                retryable = state.acceptedUser && state.anchorEntryID != nil && hasCompleteToolResults
            } else { retryable = false }
            state.pending.append(SessionTranscriptError(
                message: error.localizedDescription, provider: state.model.provider, modelID: state.model.modelID,
                errorTitle: error.transcriptTitle,
                retryState: retryable ? "available" : "unavailable", retryLeafID: persistenceLeafID
            ))
            persistPendingTranscriptErrors(state)
        }
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}

extension AgentError {
    /// 只根据真实错误线索分类，未知异常不冒充网络故障。
    public var transcriptTitle: String {
        switch self {
        case .aborted: return "已停止"
        case .invalidState: return "请求状态异常"
        case .toolNotFound, .toolBlocked: return "工具执行受阻"
        case let .llmFailed(message):
            let text = message.lowercased()
            if text.contains("401") || text.contains("403") || text.contains("unauthorized") || text.contains("authentication") { return "身份验证失败" }
            if text.contains("429") { return "请求过于频繁" }
            if text.contains("连接超时") || text.contains("timed out") { return "连接超时" }
            if text.contains("连接失败") || text.contains("nsurlerrordomain") { return "连接失败" }
            if text.contains("http") { return "服务请求失败" }
            return "模型请求失败"
        }
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
        additionalTools: [any AgentTool] = [],
        contextWindow: Int? = nil
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
            // 调用方提供模型窗口时按窗口推导压缩预算，否则用通用默认值
            compaction: contextWindow.map { CompactionConfig.recommended(contextWindow: $0) } ?? CompactionConfig(),
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
