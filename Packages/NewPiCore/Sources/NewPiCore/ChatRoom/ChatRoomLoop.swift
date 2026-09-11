import Foundation

/// 聊天室运行状态
@MainActor
public final class ChatRoomRuntime: ObservableObject {
    @Published public var chatroom: ChatRoom {
        didSet { cachedContextEstimate = nil }
    }
    @Published public var messages: [ChatRoomMessage] = [] {
        didSet { cachedContextEstimate = nil }
    }
    private var contextTokenCache = ChatRoomContextTokenCache()
    private var cachedContextEstimate: Int?

    /// 同一历史版本供状态栏、告警和压缩检查共用；增量修改只重算变化消息的字符。
    public var estimatedContextTokens: Int {
        if let cachedContextEstimate { return cachedContextEstimate }
        let estimate = contextTokenCache.estimatedTokens(room: chatroom, history: messages)
        cachedContextEstimate = estimate
        return estimate
    }
    @Published public var isRunning = false
    /// 当前角色发言/分段/输出阶段，不依赖 messages.last（用户可随时插话）。
    @Published public var liveSpeech: ChatRoomLiveSpeech?
    @Published public var currentSpeakerIndex = 0
    /// 正在发言的角色（发言期间由 loop 设置）。与 currentSpeaker（轮转索引推导）
    /// 不同：@指定发言时索引尚未推进，状态栏需要这个显式字段才能显示正确角色。
    @Published public var speakingRoleID: String?
    @Published public var error: String?
    /// 本聊天室累计 token 用量（Phase B：逐角色发言的 assistant 消息累加）。
    @Published public var usage = UsageStats()

    /// 当前发言角色（按顺序轮转）
    public var currentSpeaker: ChatRoomRole? {
        let configured = chatroom.configuredRoles
        guard !configured.isEmpty else { return nil }
        return configured[currentSpeakerIndex % configured.count]
    }

    public init(chatroom: ChatRoom) {
        self.chatroom = chatroom
        // 断点续跑（决策 #17）：currentSpeakerIndex 指向「下一个要发言的角色」
        self.currentSpeakerIndex = chatroom.currentSpeakerIndex
    }

    /// 保存当前状态到聊天室配置
    public func saveState() {
        chatroom.currentSpeakerIndex = currentSpeakerIndex
        chatroom.updatedAt = Date()
    }
}

/// 讨论结束方式（决策 #4：由用户选择，不做自动共识检测）
public enum ChatRoomDiscussionEndMode: Sendable {
    case startVoting    // 发起投票
    case proceedDirect  // 直接采用方案，跳过投票
}

/// 角色发言引擎（Phase B）：每次发言构造一个，供 AgentLoop 驱动。
/// 多模型 = 每角色不同的 llm/model 组合。
public struct ChatRoomRoleEngine: Sendable {
    public let llm: any LLMProvider
    public let model: ModelConfig

    public init(llm: any LLMProvider, model: ModelConfig) {
        self.llm = llm
        self.model = model
    }
}

/// 聊天室循环 - 多模型协作的核心逻辑
@MainActor
public final class ChatRoomLoop {
    private let store: ChatRoomStore
    private let llmFactory: any ChatRoomLLMProviderFactory
    /// 与 llmFactory 共享的审批管理器；UI 通过它观察并弹出审批卡片
    public let approvalManager: ChatRoomApprovalManager
    /// 共享上下文预算（各角色最小 context window，tokens）。
    /// 由 UI 注入（依赖 providers.json）；返回 nil 时禁用自动压缩。
    private let contextBudgetTokens: ((ChatRoom) -> Int?)?
    /// 角色发言引擎工厂（Phase B）：注入后 speak 走 AgentLoop 完整引擎
    /// （BuiltInTools + MCP + steering + 统一审批桥）；nil 时回退旧 chatWithEvents 路径。
    private let engineProvider: ((ChatRoomRole) throws -> ChatRoomRoleEngine)?
    /// MCP 工具加载器（Phase B）：注入后角色可用 MCP 工具。
    private let mcpToolsProvider: (@Sendable () async -> [any AgentTool])?
    /// 发言进行中的用户插话队列（steering）：由 AgentLoop 的 steeringProvider 消费。
    private var steeringQueue: [AgentMessage] = []
    private let auditLogger: ToolApprovalAuditLogger?

    public init(
        store: ChatRoomStore = .shared,
        llmFactory: (any ChatRoomLLMProviderFactory)? = nil,
        approvalManager: ChatRoomApprovalManager = ChatRoomApprovalManager(),
        contextBudgetTokens: ((ChatRoom) -> Int?)? = nil,
        engineProvider: ((ChatRoomRole) throws -> ChatRoomRoleEngine)? = nil,
        mcpToolsProvider: (@Sendable () async -> [any AgentTool])? = nil,
        auditLogger: ToolApprovalAuditLogger? = nil
    ) {
        self.store = store
        self.llmFactory = llmFactory ?? ChatRoomLLMProviderFactoryImpl(approvalManager: approvalManager)
        self.approvalManager = approvalManager
        self.contextBudgetTokens = contextBudgetTokens
        self.engineProvider = engineProvider
        self.mcpToolsProvider = mcpToolsProvider
        self.auditLogger = auditLogger
    }

    /// 发言进行中的用户插话：进入当前发言的 steering 队列，由 AgentLoop 在
    /// 工具批次之间投喂给正在发言的模型。
    func enqueueSteering(_ message: AgentMessage) {
        steeringQueue.append(message)
    }

    private func dequeueSteering() -> AgentMessage? {
        guard !steeringQueue.isEmpty else { return nil }
        return steeringQueue.removeFirst()
    }

    // MARK: - 阶段流转

    /// 进入下一阶段
    ///
    /// 讨论阶段的走向由用户通过 `discussionEnd` 指定（决策 #4/#19），
    /// 其余阶段按状态机推进：
    /// voting --(用户已选方案)--> execution；execution --> review；review --> completed
    public func advancePhase(
        runtime: ChatRoomRuntime,
        discussionEnd: ChatRoomDiscussionEndMode? = nil
    ) throws {
        var chatroom = runtime.chatroom

        switch chatroom.currentPhase {
        case .discussion:
            guard let discussionEnd else {
                throw ChatRoomError.invalidPhase(chatroom.currentPhase)
            }
            chatroom.currentPhase = discussionEnd == .startVoting ? .voting : .execution

            // 跳过投票时自动选定首个候选方案，避免执行提示「根据选定的方案执行」
            // 与 selectedOptionID == nil 的状态矛盾（决策 #4「直接指定方案」）
            if discussionEnd == .proceedDirect, chatroom.selectedOptionID == nil {
                let candidates = extractCandidates(from: runtime.messages)
                if let first = candidates.first {
                    chatroom.selectedOptionID = first.id
                    let message = ChatRoomMessage(
                        chatroomID: chatroom.id,
                        roleID: "user",
                        content: "📌 已确定方案：\(first.title)",
                        phase: .discussion
                    )
                    runtime.messages.append(message)
                    try store.appendMessage(message, to: chatroom.id)
                }
            }

        case .voting:
            guard chatroom.selectedOptionID != nil else {
                throw ChatRoomError.noSelectedOption
            }
            chatroom.currentPhase = .execution

        case .execution:
            chatroom.currentPhase = .review

        case .review:
            // 与 handleReviewResult 一致：暂停态必须走 addRound/completeFromPause 解锁
            guard chatroom.pausedAtRoundLimit != true else {
                throw ChatRoomError.invalidPhase(chatroom.currentPhase)
            }
            chatroom.currentPhase = .completed

        case .completed:
            return
        }

        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }

    /// Review 结果处理（决策 #8）：通过则完成；未过且未达轮数上限则回执行进入下一轮；
    /// 第 3 轮仍未过则暂停，等用户追加轮数或标记完成。
    /// 暂停状态下本方法不可用，必须走 addRoundFromPause / completeFromPause。
    public func handleReviewResult(runtime: ChatRoomRuntime, approved: Bool) throws {
        var chatroom = runtime.chatroom

        guard chatroom.currentPhase == .review, chatroom.pausedAtRoundLimit != true else {
            throw ChatRoomError.invalidPhase(chatroom.currentPhase)
        }

        if approved {
            chatroom.currentPhase = .completed
            chatroom.pausedAtRoundLimit = false
        } else if chatroom.isAtRoundLimit {
            chatroom.pausedAtRoundLimit = true
        } else {
            chatroom.reviewRoundCount += 1
            chatroom.currentPhase = .execution
        }

        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }

    /// 轮数上限暂停后：追加一轮，回执行阶段
    public func addRoundFromPause(runtime: ChatRoomRuntime) throws {
        var chatroom = runtime.chatroom

        guard chatroom.pausedAtRoundLimit == true else {
            throw ChatRoomError.invalidPhase(chatroom.currentPhase)
        }
        chatroom.pausedAtRoundLimit = false
        chatroom.reviewRoundCount += 1
        chatroom.currentPhase = .execution

        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }

    /// 轮数上限暂停后：用户接受现状，标记完成
    public func completeFromPause(runtime: ChatRoomRuntime) throws {
        var chatroom = runtime.chatroom

        guard chatroom.pausedAtRoundLimit == true else {
            throw ChatRoomError.invalidPhase(chatroom.currentPhase)
        }
        chatroom.pausedAtRoundLimit = false
        chatroom.currentPhase = .completed

        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }

    /// 用户终止整个流程（任意阶段，决策 #4「终止」）
    public func stopFlow(runtime: ChatRoomRuntime) throws {
        var chatroom = runtime.chatroom
        chatroom.currentPhase = .completed
        chatroom.pausedAtRoundLimit = false
        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }

    // MARK: - 发言

    /// 触发下一个角色发言
    public func triggerNextSpeaker(runtime: ChatRoomRuntime) async throws {
        guard runtime.chatroom.currentPhase != .completed else {
            throw ChatRoomError.invalidPhase(.completed)
        }
        guard let speaker = runtime.currentSpeaker else {
            throw ChatRoomError.roleNotConfigured("no configured roles")
        }

        try await speak(role: speaker, runtime: runtime)

        // 推进到下一个发言者，然后持久化（索引语义 = 下一个要发言的角色）
        runtime.currentSpeakerIndex += 1
        try persistRuntimeState(runtime)
    }

    /// 指定角色发言（用户 @某角色）
    public func triggerSpeaker(roleID: String, runtime: ChatRoomRuntime) async throws {
        guard runtime.chatroom.currentPhase != .completed else {
            throw ChatRoomError.invalidPhase(.completed)
        }
        guard let role = runtime.chatroom.role(by: roleID), role.isConfigured else {
            throw ChatRoomError.roleNotConfigured(roleID)
        }

        try await speak(role: role, runtime: runtime)

        if let index = runtime.chatroom.configuredRoles.firstIndex(where: { $0.id == roleID }) {
            runtime.currentSpeakerIndex = index + 1
        }
        try persistRuntimeState(runtime)
    }

    /// 用户插话
    public func userSpeak(content: String, runtime: ChatRoomRuntime) throws {
        let message = ChatRoomMessage(
            chatroomID: runtime.chatroom.id,
            roleID: "user",
            content: content,
            phase: runtime.chatroom.currentPhase
        )
        runtime.messages.append(message)
        try store.appendMessage(message, to: runtime.chatroom.id)

        // 发言进行中：同时进入 steering 队列，正在发言的模型在工具批次间即时看到
        if runtime.isRunning {
            enqueueSteering(.user(UserMessage(content: content)))
        }

        // 列表按 updatedAt 排序，插话同样刷新
        runtime.chatroom.updatedAt = Date()
        try? store.save(runtime.chatroom)
    }

    // MARK: - 投票

    /// 用户投票（决策 #19：投票后由用户手动点击「进入执行」）
    public func userVote(optionID: String, runtime: ChatRoomRuntime) throws {
        var chatroom = runtime.chatroom
        let vote = Vote(roleID: "user", optionID: optionID)
        chatroom.votes.append(vote)
        chatroom.selectedOptionID = optionID
        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom

        // 投票落到对话记录，分组展示里可见（决策：展示方式）
        let optionTitle = extractCandidates(from: runtime.messages)
            .first(where: { $0.id == optionID })?.title ?? optionID
        let message = ChatRoomMessage(
            chatroomID: chatroom.id,
            roleID: "user",
            content: "🗳️ 投票：选择「\(optionTitle)」",
            phase: chatroom.currentPhase
        )
        runtime.messages.append(message)
        try store.appendMessage(message, to: chatroom.id)
    }

    // MARK: - 内部实现

    /// 持久化运行状态（断点续跑：阶段、轮次、发言者索引）。
    /// 保存失败向上抛：静默丢失断点会让恢复行为不可预期。
    private func persistRuntimeState(_ runtime: ChatRoomRuntime) throws {
        runtime.saveState()
        try store.save(runtime.chatroom)
    }

    /// 上下文自动压缩：把检查点之后、最近 8 条之前的历史摘要成检查点。
    /// 摘要失败不阻塞发言（继续用未压缩上下文，超窗由 API 错误兜底）。
    /// provider 懒构造：仅在确认需要压缩时才创建。
    private func compactContextIfNeeded(
        runtime: ChatRoomRuntime,
        providerMaker: () throws -> any ChatRoomLLMProvider
    ) async {
        guard let budget = contextBudgetTokens?(runtime.chatroom), budget > 0 else { return }
        let estimate = runtime.estimatedContextTokens
        guard estimate >= Int(Double(budget) * 0.8) else { return }

        let keepRecent = 8
        let effective = ChatRoomContextBuilder.effectiveHistory(room: runtime.chatroom, history: runtime.messages)
        guard effective.count > keepRecent else { return }
        let toSummarize = effective.dropLast(keepRecent).filter { $0.roleID != ChatRoomContextBuilder.systemRoleID }
        guard let lastSummarized = toSummarize.last else { return }

        do {
            let provider = try providerMaker()
            let transcript = toSummarize.map { message -> String in
                let speaker: String
                if message.isUserMessage {
                    speaker = "用户"
                } else {
                    speaker = runtime.chatroom.role(by: message.roleID)?.name ?? message.roleID
                }
                return "【\(speaker)】\(message.content)" + (message.termination.map { "\n（\($0.notice)）" } ?? "")
            }.joined(separator: "\n\n")

            var prompt = "请把以下多模型协作对话压缩为要点摘要。"
            if let existing = runtime.chatroom.compactionSummary, !existing.isEmpty {
                prompt += "\n\n已有摘要（覆盖更早的历史，请融合进新摘要）：\n\(existing)"
            }
            prompt += "\n\n待压缩对话：\n\(transcript)"

            let response = try await provider.chat(
                systemPrompt: ChatRoomContextBuilder.compactionSystemPrompt,
                messages: [.user(prompt)]
            )
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty, !summary.hasPrefix("[输出被截断") else { return }

            runtime.chatroom.compactionSummary = summary
            runtime.chatroom.compactedUpToMessageID = lastSummarized.id
            runtime.chatroom.updatedAt = Date()
            try store.save(runtime.chatroom)

            // 展示用标记：roleID = system 仅用于界面，不进入模型上下文
            let marker = ChatRoomMessage(
                chatroomID: runtime.chatroom.id,
                roleID: ChatRoomContextBuilder.systemRoleID,
                content: "🧹 上下文估算 \(estimate) tokens，已达预算阈值，自动压缩早期对话（摘要 \(summary.count) 字，保留最近 \(keepRecent) 条原文）",
                phase: runtime.chatroom.currentPhase
            )
            runtime.messages.append(marker)
            try store.appendMessage(marker, to: runtime.chatroom.id)

            NewPiLogger.info(
                category: "chatroom",
                message: "Context auto-compacted",
                details: """
                estimate=\(estimate) budget=\(budget)
                summarized=\(toSummarize.count) summaryChars=\(summary.count)
                """
            )
        } catch {
            NewPiLogger.error(
                category: "chatroom",
                message: "Context compaction failed, continuing without compaction",
                details: error.localizedDescription
            )
        }
    }

    /// 角色发言
    private func speak(role: ChatRoomRole, runtime: ChatRoomRuntime) async throws {
        guard !runtime.isRunning else { throw AgentError.invalidState("聊天室已有发言正在进行") }
        try Task.checkCancellation()
        guard let providerID = role.providerProfileID,
              let modelID = role.modelID else {
            throw ChatRoomError.roleNotConfigured(role.id)
        }

        runtime.isRunning = true
        runtime.speakingRoleID = role.id
        defer {
            runtime.isRunning = false
            runtime.speakingRoleID = nil
        }
        // steering 队列只在发言生命周期内有效：插话内容早已写入共享历史，
        // 未被当轮消费（纯文本发言/多条剩余）的残留在此丢弃，避免下次发言重复投喂
        defer { steeringQueue.removeAll() }

        let candidates = extractCandidates(from: runtime.messages)

        if engineProvider != nil {
            // Phase B：AgentLoop 引擎路径
            try await speakWithEngine(role, runtime: runtime, candidates: candidates)
        } else {
            // 旧路径（Phase B 回退保留）：自研 agentic loop + ChatRoomTools
            try await speakWithProvider(role, runtime: runtime, providerID: providerID, modelID: modelID, candidates: candidates)
        }
    }

    /// Phase B：AgentLoop 引擎路径——完整工具链（read/write/edit/bash + MCP）、
    /// 统一审批桥、steering 插话、turn 内压缩、用量统计、历史修复。
    private func speakWithEngine(
        _ role: ChatRoomRole,
        runtime: ChatRoomRuntime,
        candidates: [CandidateOption]
    ) async throws {
        let engine = try engineProvider?(role) ?? { throw ChatRoomError.roleNotConfigured(role.id) }()

        let projectURL = URL(fileURLWithPath: runtime.chatroom.projectPath)

        // 决策 #7：发言前压缩检查（摘要检查点，与旧路径一致）；provider 懒构造
        await compactContextIfNeeded(runtime: runtime, providerMaker: {
            try llmFactory.createProvider(
                profileID: role.providerProfileID ?? "",
                modelID: role.modelID ?? "",
                projectPath: runtime.chatroom.projectPath,
                roleID: role.id,
                roleName: role.name,
                thinkingLevel: role.thinkingLevel
            )
        })
        try Task.checkCancellation()

        let systemPrompt = ChatRoomContextBuilder.systemPrompt(
            role: role,
            phase: runtime.chatroom.currentPhase,
            reviewRoundCount: runtime.chatroom.reviewRoundCount,
            candidates: candidates,
            selectedOptionID: runtime.chatroom.selectedOptionID
        )
        let historyMessages = ChatRoomContextBuilder.buildAgentContext(
            room: runtime.chatroom,
            history: runtime.messages
        )

        // 触发消息与末条合并：AgentLoop 对 prompt 无条件 append 且不合并同角色，
        // 共享历史以 user 结尾（如插话后推进）时会产生 [user, user] 被 Anthropic 拒绝
        var runMessages = historyMessages
        let trigger = ChatRoomContextBuilder.triggerText(for: role)
        let promptMessage: AgentMessage
        if case .user(let last)? = runMessages.last {
            promptMessage = .user(UserMessage(content: last.content + "\n\n" + trigger))
            runMessages.removeLast()
        } else {
            promptMessage = .user(UserMessage(content: trigger))
        }

        // 实时进度：按 agentic 迭代分段（对齐 session 的交错展示）——每次 turnStart
        // 起一条新消息（共享 speechID），思考/文本/工具事件只改写当前段；
        // 全部段在发言结束时统一去空、定型，与插话一起原子保存显示顺序。
        let speechID = UUID().uuidString

        let buffer = ChatRoomSpeechBuffer(runtime: runtime, speechID: speechID)
        let approvalGate = ChatRoomApprovalEventGate()
        defer { buffer.finish(); approvalGate.finish() }
        var lastAssistantText = ""
        var errorMessage: String?
        var sawAbort = false

        func appendSegment() {
            buffer.beginSegment(ChatRoomMessage(
                chatroomID: runtime.chatroom.id,
                roleID: role.id,
                content: "",
                speechID: speechID,
                phase: runtime.chatroom.currentPhase
            ))
        }

        func mutateCurrentSegment(_ mutate: (inout ChatRoomMessage) -> Void) {
            guard let index = runtime.messages.lastIndex(where: { $0.speechID == speechID }) else { return }
            mutate(&runtime.messages[index])
        }

        func appendToolCall(_ call: ChatRoomToolCall) {
            mutateCurrentSegment { message in
                if !(message.toolCalls ?? []).contains(where: { $0.id == call.id }) {
                    message.toolCalls = (message.toolCalls ?? []) + [call]
                }
            }
        }

        func appendToolResult(_ result: ChatRoomToolResult) {
            mutateCurrentSegment { message in
                message.toolResults = (message.toolResults ?? []) + [result]
            }
        }

        @MainActor func applyAgentEvent(_ event: AgentEvent) {
            // 所有非增量事件都是显示边界；尤其审批可能长时间等待，不能把尾字留在缓冲。
            switch event {
            case .textDelta, .thinkingDelta: break
            default: buffer.flush()
            }
            switch event {
            case .turnStart:
                // 新迭代 = 新分段；上一段的流式内容在此定格
                appendSegment()
            case .textDelta(let delta):
                buffer.appendText(delta)
            case .thinkingDelta(let delta):
                buffer.appendThinking(delta)
            case .toolApprovalRequired(let request):
                approvalGate.reach(request.id)
            case .toolExecutionStart(let id, let name, let arguments):
                appendToolCall(ChatRoomToolCall(
                    id: id,
                    name: name,
                    arguments: ChatRoomLLMProviderImpl.argumentsString(arguments)
                ))
            case .toolExecutionEnd(let id, _, let result):
                appendToolResult(ChatRoomToolResult(
                    toolCallID: id,
                    output: result.content,
                    isError: result.isError
                ))
            case .messageEnd(.assistant(let assistant)):
                buffer.completeMessage()
                // 用最终消息补齐正文/工具声明。审批前已知的工具先入条目，避免将中间解说误当最终回答。
                mutateCurrentSegment { message in
                    message.content = assistant.text
                    message.reasoningContent = assistant.reasoningContent.isEmpty ? nil : assistant.reasoningContent
                }
                for call in assistant.toolCalls {
                    appendToolCall(ChatRoomToolCall(id: call.id, name: call.name,
                        arguments: ChatRoomLLMProviderImpl.argumentsString(call.arguments)))
                }
                // 用量累计 + 候选方案取自最后一轮 assistant 正文（决策 #16）
                runtime.usage.add(assistant.usage)
                if !assistant.text.isEmpty {
                    lastAssistantText = assistant.text
                }
            case .error(.aborted):
                sawAbort = true
            case .error(let error):
                errorMessage = error.localizedDescription
            default:
                break
            }
        }

        do {
            var mcpTools: [any AgentTool] = []
            if let mcpToolsProvider {
                mcpTools = await mcpToolsProvider()
            }

            try Task.checkCancellation()
            let approvalPolicy = approvalManager.policyStore.load()
            let config = AgentLoopConfig(
                model: engine.model,
                llm: engine.llm,
                tools: Self.chatroomTools(projectURL: projectURL, additional: mcpTools),
                toolPolicy: ToolPolicyRules(requireApprovalFor: ["write", "edit", "bash"]),
                compaction: contextBudgetTokens?(runtime.chatroom)
                    .map { CompactionConfig.recommended(contextWindow: $0) } ?? CompactionConfig(),
                maxTurns: 500,
                requestToolApproval: { [weak approvalManager] request in
                    // 先等消费端处理完审批之前的事件，避免主线程繁忙时弹框先于尾字上屏。
                    guard await approvalGate.wait(for: request.id) else { return .deny }
                    guard let approvalManager else { return .deny }
                    return await approvalManager.approvalDecision(
                        for: request,
                        roleID: role.id,
                        roleName: role.name
                    )
                },
                toolApprovalTracker: approvalManager.tracker,
                dangerEvaluator: DangerEvaluator(policy: approvalPolicy,
                    llmSupplementEnabled: approvalPolicy.llmSupplementEnabled),
                dangerCache: DangerAssessmentCache(),
                // 项目根内文件操作免审批（PROJECT-SCOPE-AUTO-APPROVE）：
                // 根 = 聊天室 projectPath，开关走持久化策略。
                projectScope: ProjectScopePolicy(
                    root: projectURL,
                    isEnabled: approvalPolicy.projectScopeAutoApprove
                ),
                auditLogger: auditLogger
            )

            let stream = AgentLoop().run(
                prompt: promptMessage,
                context: AgentContext(
                    systemPrompt: systemPrompt,
                    messages: runMessages,
                    workingDirectory: projectURL
                ),
                config: config,
                steeringProvider: { [weak self] in await self?.dequeueSteering() }
            )

            await buffer.consume(stream, applyEvent: applyAgentEvent)
        } catch {
            buffer.completeMessage()
            let cancelled = Task.isCancelled || error is CancellationError || (error as? AgentError) == .aborted
            try preserveInterruptedSpeech(runtime: runtime, speechID: speechID,
                termination: cancelled ? .cancelled : .failed)
            if cancelled { throw CancellationError() }
            throw error
        }

        buffer.completeMessage()
        if sawAbort || Task.isCancelled {
            try preserveInterruptedSpeech(runtime: runtime, speechID: speechID, termination: .cancelled)
            throw CancellationError()
        }

        // 去空段：无思考/无工具/无文本的迭代不留痕（全部为空时保留最后一段兜底）
        var segments = runtime.messages.filter { $0.speechID == speechID }
        let nonEmpty = segments.filter {
            !$0.content.isEmpty || ($0.reasoningContent?.isEmpty == false) || ($0.toolCalls?.isEmpty == false)
        }
        if !nonEmpty.isEmpty, nonEmpty.count != segments.count {
            let keepIDs = Set(nonEmpty.map(\.id))
            runtime.messages.removeAll { $0.speechID == speechID && !keepIDs.contains($0.id) }
            segments = nonEmpty
        }

        if let errorMessage {
            mutateCurrentSegment { $0.content += "\n\n（发言失败：\(errorMessage)）" }
        }

        // 候选方案只在讨论阶段解析（决策 #16 的「收尾归纳」语义），挂最后一段
        if errorMessage == nil, runtime.chatroom.currentPhase == .discussion, !lastAssistantText.isEmpty {
            mutateCurrentSegment { message in
                message.candidates = ChatRoomCandidateParser.parse(from: lastAssistantText)
            }
        }

        if errorMessage != nil {
            try preserveInterruptedSpeech(runtime: runtime, speechID: speechID, termination: .failed)
        } else {
            // 包含已经落盘的插话：原子保存当前顺序，避免重启后插话跑到本次发言前面。
            try store.saveMessages(runtime.messages, for: runtime.chatroom.id)
        }
    }

    /// 中断不是撤销：保留已经看见的文字、思考和工具结果；不声称未知的工具已经回滚。
    private func preserveInterruptedSpeech(
        runtime: ChatRoomRuntime, speechID: String, termination: ChatRoomSpeechTermination
    ) throws {
        runtime.messages.removeAll { message in
            (message.speechID ?? message.id) == speechID && message.content.isEmpty
                && (message.reasoningContent ?? "").isEmpty && (message.toolCalls ?? []).isEmpty
        }
        guard runtime.messages.contains(where: { ($0.speechID ?? $0.id) == speechID }) else { return }
        for index in runtime.messages.indices where (runtime.messages[index].speechID ?? runtime.messages[index].id) == speechID {
            var message = runtime.messages[index]
            message.termination = termination
            var results = message.toolResults ?? []
            for call in message.toolCalls ?? [] where !results.contains(where: { $0.toolCallID == call.id }) {
                results.append(ChatRoomToolResult(toolCallID: call.id,
                    output: "发言已中断，未收到该工具的结果。操作可能尚未执行，也可能已部分执行；请检查实际文件状态。",
                    isError: true))
            }
            message.toolResults = results.isEmpty ? nil : results
            runtime.messages[index] = message
        }
        try store.saveMessages(runtime.messages, for: runtime.chatroom.id)
        try persistRuntimeState(runtime)
    }

    /// 聊天室引擎工具集：session 的 BuiltInTools（不含 SubAgent），edit 快照挂项目目录。
    static func chatroomTools(projectURL: URL, additional: [any AgentTool]) -> [any AgentTool] {
        var tools: [any AgentTool] = [
            ReadTool(),
            WriteTool(),
            EditTool(snapshotStore: .forProject(projectURL)),
            BashTool(),
        ]
        tools.append(contentsOf: additional)
        return tools
    }

    /// 旧路径（Phase B 回退保留）：自研 agentic loop + ChatRoomTools。
    private func speakWithProvider(
        _ role: ChatRoomRole,
        runtime: ChatRoomRuntime,
        providerID: String,
        modelID: String,
        candidates: [CandidateOption]
    ) async throws {
        let provider = try llmFactory.createProvider(
            profileID: providerID,
            modelID: modelID,
            projectPath: runtime.chatroom.projectPath,
            roleID: role.id,
            roleName: role.name,
            thinkingLevel: role.thinkingLevel
        )

        // 决策 #7（2026-09-05 调整）：上下文估算达到预算 80% 时自动压缩。
        // 必须在构建 systemPrompt/上下文之前执行，当轮发言才能用上摘要。
        await compactContextIfNeeded(runtime: runtime, providerMaker: { provider })
        try Task.checkCancellation()

        let systemPrompt = ChatRoomContextBuilder.systemPrompt(
            role: role,
            phase: runtime.chatroom.currentPhase,
            reviewRoundCount: runtime.chatroom.reviewRoundCount,
            candidates: candidates,
            selectedOptionID: runtime.chatroom.selectedOptionID
        )
        let contextMessages = ChatRoomContextBuilder.messages(
            room: runtime.chatroom,
            history: runtime.messages,
            nextSpeaker: role
        )

        // 兼容 provider 路径也使用显式发言身份和合并器；中断时保留可见内容。
        let liveMessageID = UUID().uuidString
        let buffer = ChatRoomSpeechBuffer(runtime: runtime, speechID: liveMessageID)
        defer { buffer.finish() }
        buffer.beginSegment(ChatRoomMessage(
            id: liveMessageID,
            chatroomID: runtime.chatroom.id,
            roleID: role.id,
            content: "",
            phase: runtime.chatroom.currentPhase
        ))
        let liveIndex = runtime.messages.count - 1

        func applySpeechEvent(_ event: ChatRoomSpeechEvent) {
            // 临时消息必须仍在原位（未被并发修改/移除）才应用事件
            guard runtime.messages.indices.contains(liveIndex),
                  runtime.messages[liveIndex].id == liveMessageID else { return }

            switch event {
            case .thinkingDelta(let delta):
                buffer.appendThinking(delta)
            case .textDelta(let delta):
                buffer.appendText(delta)
            case .toolStarted(let call):
                buffer.completeMessage()
                var calls = runtime.messages[liveIndex].toolCalls ?? []
                calls.append(call)
                runtime.messages[liveIndex].toolCalls = calls
            case .toolFinished(let result):
                buffer.flush()
                var results = runtime.messages[liveIndex].toolResults ?? []
                results.append(result)
                runtime.messages[liveIndex].toolResults = results
            }
        }

        do {
            let response = try await provider.chatWithEvents(
                systemPrompt: systemPrompt,
                messages: contextMessages,
                onEvent: { applySpeechEvent($0) }
            )

            buffer.completeMessage()
            try Task.checkCancellation()
            // 定型：以最终响应覆盖实时内容（agentic loop 多轮的中间文本以最终轮为准）
            let messageCandidates = runtime.chatroom.currentPhase == .discussion ? response.candidates : nil
            runtime.messages[liveIndex].content = response.content
            runtime.messages[liveIndex].reasoningContent = response.reasoningContent.isEmpty ? nil : response.reasoningContent
            runtime.messages[liveIndex].candidates = messageCandidates
            runtime.messages[liveIndex].toolCalls = response.toolCalls.isEmpty ? nil : response.toolCalls
            runtime.messages[liveIndex].toolResults = response.toolResults.isEmpty ? nil : response.toolResults

            try store.saveMessages(runtime.messages, for: runtime.chatroom.id)
        } catch {
            buffer.completeMessage()
            let cancelled = Task.isCancelled || error is CancellationError || (error as? AgentError) == .aborted
            try preserveInterruptedSpeech(runtime: runtime, speechID: liveMessageID,
                termination: cancelled ? .cancelled : .failed)
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    /// 从消息中提取候选方案（取最近一条带候选方案的消息）
    private func extractCandidates(from messages: [ChatRoomMessage]) -> [CandidateOption] {
        for message in messages.reversed() {
            if let candidates = message.candidates, !candidates.isEmpty {
                return candidates
            }
        }
        return []
    }
}

// MARK: - 上下文构建

/// 构建角色发言上下文（public，供 UI 预算提示与单元测试复用）
///
/// - 各角色发言带「【角色名】」署名前缀，模型能区分发言人
/// - 合并连续同角色消息：Anthropic Messages API 要求 user/assistant 严格交替
/// - 阶段提示并入 systemPrompt，不再作为消息插入（避免产生连续 user 消息）
/// - 压缩检查点（决策 #7，2026-09-05 调整）：检查点之前的历史由摘要替代，
///   仅影响模型上下文，messages.jsonl 的记录保持完整
public enum ChatRoomContextBuilder {
    /// 展示专用的系统标记消息 roleID：不进入模型上下文、不参与压缩摘要
    public static let systemRoleID = "system"

    /// 自动压缩的摘要生成提示词
    public static let compactionSystemPrompt = """
        你负责压缩多模型协作聊天室的历史对话。请把输入的对话压缩为要点摘要，保留：
        - 用户的原始任务与目标
        - 已选定的方案与关键决策（含方案标题）
        - 各角色的重要结论、分歧与承诺
        - 已完成的文件改动与待办事项
        用简体中文输出纯文本摘要，不要评论，不要调用任何工具。
        """

    /// 构建模型实际收到的历史：检查点之后的消息（无检查点则为全部）。
    /// 仅当摘要存在且检查点可定位时生效，否则回退完整历史。
    public static func effectiveHistory(room: ChatRoom, history: [ChatRoomMessage]) -> [ChatRoomMessage] {
        guard let summary = room.compactionSummary, !summary.isEmpty,
              let checkpointID = room.compactedUpToMessageID, !checkpointID.isEmpty,
              let index = history.firstIndex(where: { $0.id == checkpointID }) else {
            return history
        }
        return Array(history[history.index(after: index)...])
    }

    /// 估算构建上下文的 token 占用（含摘要、检查点后的历史、systemPrompt 近似开销）。
    /// 工具结果不跨发言重放，故不计入（与实际 API 载荷一致）。
    public static func estimatedTokens(room: ChatRoom, history: [ChatRoomMessage]) -> Int {
        var cache = ChatRoomContextTokenCache()
        return cache.estimatedTokens(room: room, history: history)
    }

    static func systemPrompt(
        role: ChatRoomRole,
        phase: ChatRoomPhase,
        reviewRoundCount: Int,
        candidates: [CandidateOption],
        selectedOptionID: String? = nil
    ) -> String {
        let phaseHint: String
        switch phase {
        case .discussion:
            phaseHint = """
                当前处于【讨论阶段】。请围绕问题展开讨论，提出你的方案和建议。
                讨论收尾归纳候选方案时，请在回复末尾用 ```json 代码块输出方案数组，格式：
                [{"title": "方案标题", "description": "简要说明"}]；没有候选方案可省略。
                """
        case .voting:
            if candidates.isEmpty {
                phaseHint = "当前处于【投票阶段】。请对候选方案表态。"
            } else {
                var hint = "当前处于【投票阶段】。请对以下候选方案表态，说明你支持哪个及理由："
                for (index, option) in candidates.enumerated() {
                    hint += "\n\(index + 1). \(option.title)：\(option.description)"
                }
                phaseHint = hint
            }
        case .execution:
            let roundSuffix = reviewRoundCount > 1 ? "（第 \(reviewRoundCount) 轮修改）" : ""
            if let selected = candidates.first(where: { $0.id == selectedOptionID }) {
                phaseHint = "当前处于【执行阶段】\(roundSuffix)。选定方案为「\(selected.title)」（\(selected.description)），请据此执行，可用工具读写项目文件。"
            } else if candidates.isEmpty {
                phaseHint = "当前处于【执行阶段】\(roundSuffix)。请根据讨论中形成的共识执行，可用工具读写项目文件。"
            } else {
                phaseHint = "当前处于【执行阶段】\(roundSuffix)。请根据选定的方案执行，可用工具读写项目文件。"
            }
        case .review:
            phaseHint = "当前处于【Review 阶段】。请用工具审查代码改动，发现问题请指出；确认没问题请明确表示通过。"
        case .completed:
            phaseHint = "任务已完成。"
        }
        return role.systemPrompt + "\n\n" + phaseHint
    }

    /// 构建共享历史为 AgentMessage 上下文（Phase B：供 AgentLoop 的 AgentContext 使用）。
    /// 与 `messages` 同一套规则：署名前缀、连续同角色合并、检查点摘要、跳过系统标记、
    /// 首条 user 兜底。不含末尾触发消息（由 AgentLoop 的 prompt 承担）。
    public static func buildAgentContext(room: ChatRoom, history: [ChatRoomMessage]) -> [AgentMessage] {
        var context: [AgentMessage] = []

        for msg in effectiveHistory(room: room, history: history) {
            // 展示专用标记不进入模型上下文
            if msg.roleID == systemRoleID { continue }

            let message: AgentMessage
            if msg.isUserMessage {
                guard !msg.content.isEmpty else { continue }
                message = .user(UserMessage(content: msg.content))
            } else {
                let speakerName = room.role(by: msg.roleID)?.name ?? msg.roleID
                var text = msg.content
                // 纯工具调用轮（无文本）：给一行摘要，避免空 assistant 消息被 API 拒绝
                if text.isEmpty, let calls = msg.toolCalls, !calls.isEmpty {
                    text = "（调用工具: " + calls.map { $0.name }.joined(separator: ", ") + "）"
                }
                if let termination = msg.termination { text += "\n\n（\(termination.notice)）" }
                guard !text.isEmpty else { continue }
                message = .assistant(AssistantMessage(
                    text: "【\(speakerName)】\(text)",
                    provider: "chatroom",
                    modelID: msg.roleID,
                    stopReason: .stop
                ))
            }

            if case .assistant(let last)? = context.last,
               case .assistant(let new) = message {
                context[context.count - 1] = .assistant(AssistantMessage(
                    text: last.text + "\n\n" + new.text,
                    provider: new.provider,
                    modelID: new.modelID,
                    stopReason: .stop
                ))
            } else if case .user(let last)? = context.last,
                      case .user(let new) = message {
                context[context.count - 1] = .user(UserMessage(content: last.content + "\n\n" + new.content))
            } else {
                context.append(message)
            }
        }

        // 历史摘要置于上下文开头；与首条 user 合并以保持角色交替
        if let summary = room.compactionSummary, !summary.isEmpty {
            let summaryContent = "【历史摘要】\(summary)"
            if case .user(let first)? = context.first {
                context[0] = .user(UserMessage(content: summaryContent + "\n\n" + first.content))
            } else {
                context.insert(.user(UserMessage(content: summaryContent)), at: 0)
            }
        }

        // Anthropic 要求首条消息必须是 user（摘要兜底后一般已满足）
        if case .assistant? = context.first {
            let lead = room.description.isEmpty ? "（用户尚未发言，请直接开始）" : "【任务背景】\(room.description)"
            context.insert(.user(UserMessage(content: lead)), at: 0)
        }

        return context
    }

    /// 合成触发消息：追加在上下文末尾（AgentLoop 的 prompt），把「该谁发言」对模型显式化
    public static func triggerText(for nextSpeaker: ChatRoomRole?) -> String {
        if let nextSpeaker {
            return "（请以【\(nextSpeaker.name)】的身份发言，不要延续其他角色的发言内容）"
        }
        return "（请继续发言）"
    }

    static func messages(
        room: ChatRoom,
        history: [ChatRoomMessage],
        nextSpeaker: ChatRoomRole? = nil
    ) -> [ChatRoomLLMMessage] {
        var out = buildAgentContext(room: room, history: history).map { message -> ChatRoomLLMMessage in
            switch message {
            case .user(let user):
                return .user(user.content)
            case .assistant(let assistant):
                return .assistant(assistant.text)
            default:
                return .user("")
            }
        }

        // 末条不能是 assistant：Anthropic 会把结尾 assistant 当作 prefill 续写上文，
        // 而不是让新角色发言。追加一条合成触发消息（仅在本次构建的上下文里，
        // 不写入对话记录），同时把「该谁发言」对模型显式化。
        if let last = out.last, last.role == .assistant {
            out.append(.user(triggerText(for: nextSpeaker)))
        }

        return out
    }
}

// MARK: - ChatRoom LLM 相关类型

public struct ChatRoomLLMMessage: Sendable {
    public var role: ChatRoomMessageRole
    public var content: String

    public init(role: ChatRoomMessageRole, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatRoomLLMMessage {
        ChatRoomLLMMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> ChatRoomLLMMessage {
        ChatRoomLLMMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> ChatRoomLLMMessage {
        ChatRoomLLMMessage(role: .assistant, content: content)
    }
}

public enum ChatRoomMessageRole: Sendable {
    case system
    case user
    case assistant
}

public struct ChatRoomLLMResponse: Sendable {
    public var content: String
    /// 最后一轮思考过程文本（extended thinking）；未开启思考时为空
    public var reasoningContent: String
    public var candidates: [CandidateOption]?
    public var toolCalls: [ChatRoomToolCall]
    public var toolResults: [ChatRoomToolResult]

    public init(
        content: String,
        reasoningContent: String = "",
        candidates: [CandidateOption]? = nil,
        toolCalls: [ChatRoomToolCall] = [],
        toolResults: [ChatRoomToolResult] = []
    ) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.candidates = candidates
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

// MARK: - ChatRoom LLM Provider 协议

public protocol ChatRoomLLMProvider: Sendable {
    func chat(
        systemPrompt: String,
        messages: [ChatRoomLLMMessage]
    ) async throws -> ChatRoomLLMResponse

    /// 必须是协议要求：app 通过 `any ChatRoomLLMProvider` 存在容器调用，
    /// 若只放在 extension 里，Swift 会静态派发到扩展默认实现、丢弃 onEvent
    /// （2026-09-05 实时显示不生效的根因）。
    func chatWithEvents(
        systemPrompt: String,
        messages: [ChatRoomLLMMessage],
        onEvent: (@MainActor @Sendable (ChatRoomSpeechEvent) -> Void)?
    ) async throws -> ChatRoomLLMResponse
}

public extension ChatRoomLLMProvider {
    /// 默认实现：无事件，转发 chat——只实现 chat 的类型（测试 mock）由此满足要求。
    func chatWithEvents(
        systemPrompt: String,
        messages: [ChatRoomLLMMessage],
        onEvent: (@MainActor @Sendable (ChatRoomSpeechEvent) -> Void)?
    ) async throws -> ChatRoomLLMResponse {
        try await chat(systemPrompt: systemPrompt, messages: messages)
    }
}

// MARK: - ChatRoom LLM Provider Factory Protocol

public protocol ChatRoomLLMProviderFactory: Sendable {
    func createProvider(
        profileID: String,
        modelID: String,
        projectPath: String,
        roleID: String,
        roleName: String,
        thinkingLevel: ThinkingLevel?
    ) throws -> ChatRoomLLMProvider
}
