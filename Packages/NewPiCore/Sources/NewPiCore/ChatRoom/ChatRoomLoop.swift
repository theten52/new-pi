import Foundation

/// 聊天室运行状态
@MainActor
public final class ChatRoomRuntime: ObservableObject {
    @Published public var chatroom: ChatRoom
    @Published public var messages: [ChatRoomMessage] = []
    @Published public var isRunning = false
    @Published public var currentSpeakerIndex = 0
    @Published public var error: String?

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

    public init(
        store: ChatRoomStore = .shared,
        llmFactory: (any ChatRoomLLMProviderFactory)? = nil,
        approvalManager: ChatRoomApprovalManager = ChatRoomApprovalManager(),
        contextBudgetTokens: ((ChatRoom) -> Int?)? = nil
    ) {
        self.store = store
        self.llmFactory = llmFactory ?? ChatRoomLLMProviderFactoryImpl(approvalManager: approvalManager)
        self.approvalManager = approvalManager
        self.contextBudgetTokens = contextBudgetTokens
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
    private func compactContextIfNeeded(runtime: ChatRoomRuntime, provider: ChatRoomLLMProvider) async {
        guard let budget = contextBudgetTokens?(runtime.chatroom), budget > 0 else { return }
        let estimate = ChatRoomContextBuilder.estimatedTokens(room: runtime.chatroom, history: runtime.messages)
        guard estimate >= Int(Double(budget) * 0.8) else { return }

        let keepRecent = 8
        let effective = ChatRoomContextBuilder.effectiveHistory(room: runtime.chatroom, history: runtime.messages)
        guard effective.count > keepRecent else { return }
        let toSummarize = effective.dropLast(keepRecent).filter { $0.roleID != ChatRoomContextBuilder.systemRoleID }
        guard let lastSummarized = toSummarize.last else { return }

        do {
            let transcript = toSummarize.map { message -> String in
                let speaker: String
                if message.isUserMessage {
                    speaker = "用户"
                } else {
                    speaker = runtime.chatroom.role(by: message.roleID)?.name ?? message.roleID
                }
                return "【\(speaker)】\(message.content)"
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
        guard let providerID = role.providerProfileID,
              let modelID = role.modelID else {
            throw ChatRoomError.roleNotConfigured(role.id)
        }

        runtime.isRunning = true
        defer { runtime.isRunning = false }

        let candidates = extractCandidates(from: runtime.messages)

        let provider = try llmFactory.createProvider(
            profileID: providerID,
            modelID: modelID,
            projectPath: runtime.chatroom.projectPath,
            roleID: role.id,
            roleName: role.name
        )

        // 决策 #7（2026-09-05 调整）：上下文估算达到预算 80% 时自动压缩。
        // 必须在构建 systemPrompt/上下文之前执行，当轮发言才能用上摘要。
        await compactContextIfNeeded(runtime: runtime, provider: provider)

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

        // 实时进度（与 Session 流式体验对齐）：先挂一条临时消息，流式增量与
        // 工具事件实时改写它；发言结束才落盘，失败则移除临时消息。
        // 临时消息不写入 messages.jsonl，持久化只发生在定型之后。
        let liveMessageID = UUID().uuidString
        runtime.messages.append(ChatRoomMessage(
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
            case .textDelta(let delta):
                runtime.messages[liveIndex].content += delta
            case .toolStarted(let call):
                var calls = runtime.messages[liveIndex].toolCalls ?? []
                calls.append(call)
                runtime.messages[liveIndex].toolCalls = calls
            case .toolFinished(let result):
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

            // 定型：以最终响应覆盖实时内容（agentic loop 多轮的中间文本以最终轮为准）
            let messageCandidates = runtime.chatroom.currentPhase == .discussion ? response.candidates : nil
            runtime.messages[liveIndex].content = response.content
            runtime.messages[liveIndex].candidates = messageCandidates
            runtime.messages[liveIndex].toolCalls = response.toolCalls.isEmpty ? nil : response.toolCalls
            runtime.messages[liveIndex].toolResults = response.toolResults.isEmpty ? nil : response.toolResults

            try store.appendMessage(runtime.messages[liveIndex], to: runtime.chatroom.id)
        } catch {
            // 移除未完成的临时消息，错误向上抛给 UI
            if runtime.messages.indices.contains(liveIndex),
               runtime.messages[liveIndex].id == liveMessageID {
                runtime.messages.remove(at: liveIndex)
            }
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
        // 角色 systemPrompt + 阶段提示 + 触发消息的近似开销
        var total = 400
        if let summary = room.compactionSummary, !summary.isEmpty {
            total += ContextTokenEstimator.estimate(text: summary) + 16
        }
        for message in effectiveHistory(room: room, history: history) where message.roleID != systemRoleID {
            total += ContextTokenEstimator.estimate(text: message.content) + 8
        }
        return total
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

    static func messages(
        room: ChatRoom,
        history: [ChatRoomMessage],
        nextSpeaker: ChatRoomRole? = nil
    ) -> [ChatRoomLLMMessage] {
        var context: [ChatRoomLLMMessage] = []

        for msg in effectiveHistory(room: room, history: history) {
            // 展示专用标记不进入模型上下文
            if msg.roleID == systemRoleID { continue }

            let message: ChatRoomLLMMessage
            if msg.isUserMessage {
                guard !msg.content.isEmpty else { continue }
                message = .user(msg.content)
            } else {
                let speakerName = room.role(by: msg.roleID)?.name ?? msg.roleID
                var text = msg.content
                // 纯工具调用轮（无文本）：给一行摘要，避免空 assistant 消息被 API 拒绝
                if text.isEmpty, let calls = msg.toolCalls, !calls.isEmpty {
                    text = "（调用工具: " + calls.map { $0.name }.joined(separator: ", ") + "）"
                }
                guard !text.isEmpty else { continue }
                message = .assistant("【\(speakerName)】\(text)")
            }

            if let last = context.last, last.role == message.role {
                context[context.count - 1] = ChatRoomLLMMessage(
                    role: last.role,
                    content: last.content + "\n\n" + message.content
                )
            } else {
                context.append(message)
            }
        }

        // 历史摘要置于上下文开头；与首条 user 合并以保持角色交替
        if let summary = room.compactionSummary, !summary.isEmpty {
            let summaryContent = "【历史摘要】\(summary)"
            if let first = context.first, first.role == .user {
                context[0] = ChatRoomLLMMessage(role: .user, content: summaryContent + "\n\n" + first.content)
            } else {
                context.insert(.user(summaryContent), at: 0)
            }
        }

        // Anthropic 要求首条消息必须是 user（摘要兜底后一般已满足）
        if let first = context.first, first.role == .assistant {
            let lead = room.description.isEmpty ? "（用户尚未发言，请直接开始）" : "【任务背景】\(room.description)"
            context.insert(.user(lead), at: 0)
        }

        // 末条不能是 assistant：Anthropic 会把结尾 assistant 当作 prefill 续写上文，
        // 而不是让新角色发言。追加一条合成触发消息（仅在本次构建的上下文里，
        // 不写入对话记录），同时把「该谁发言」对模型显式化。
        if let last = context.last, last.role == .assistant {
            let trigger: String
            if let nextSpeaker {
                trigger = "（请以【\(nextSpeaker.name)】的身份发言，不要延续其他角色的发言内容）"
            } else {
                trigger = "（请继续发言）"
            }
            context.append(.user(trigger))
        }

        return context
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
    public var candidates: [CandidateOption]?
    public var toolCalls: [ChatRoomToolCall]
    public var toolResults: [ChatRoomToolResult]

    public init(
        content: String,
        candidates: [CandidateOption]? = nil,
        toolCalls: [ChatRoomToolCall] = [],
        toolResults: [ChatRoomToolResult] = []
    ) {
        self.content = content
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
}

public extension ChatRoomLLMProvider {
    /// 带实时事件的发言：onEvent 在 MainActor 上按序回调（文本增量节流、
    /// 工具开始/完成）。默认实现不产生事件，直接转发 chat。
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
        roleName: String
    ) throws -> ChatRoomLLMProvider
}
