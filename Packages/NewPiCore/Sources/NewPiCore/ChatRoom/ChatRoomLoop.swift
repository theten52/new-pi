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

    public init(
        store: ChatRoomStore = .shared,
        llmFactory: (any ChatRoomLLMProviderFactory)? = nil,
        approvalManager: ChatRoomApprovalManager = ChatRoomApprovalManager()
    ) {
        self.store = store
        self.llmFactory = llmFactory ?? ChatRoomLLMProviderFactoryImpl(approvalManager: approvalManager)
        self.approvalManager = approvalManager
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

    /// 角色发言
    private func speak(role: ChatRoomRole, runtime: ChatRoomRuntime) async throws {
        guard let providerID = role.providerProfileID,
              let modelID = role.modelID else {
            throw ChatRoomError.roleNotConfigured(role.id)
        }

        runtime.isRunning = true
        defer { runtime.isRunning = false }

        let candidates = extractCandidates(from: runtime.messages)
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

        let provider = try llmFactory.createProvider(
            profileID: providerID,
            modelID: modelID,
            projectPath: runtime.chatroom.projectPath,
            roleID: role.id,
            roleName: role.name
        )

        let response = try await provider.chat(
            systemPrompt: systemPrompt,
            messages: contextMessages
        )

        // 候选方案只在讨论阶段解析（决策 #16 的「收尾归纳」语义），
        // 避免 Voting/Review 等阶段的回复被误当成候选方案
        let messageCandidates = runtime.chatroom.currentPhase == .discussion ? response.candidates : nil

        let message = ChatRoomMessage(
            chatroomID: runtime.chatroom.id,
            roleID: role.id,
            content: response.content,
            phase: runtime.chatroom.currentPhase,
            candidates: messageCandidates,
            toolCalls: response.toolCalls.isEmpty ? nil : response.toolCalls,
            toolResults: response.toolResults.isEmpty ? nil : response.toolResults
        )

        runtime.messages.append(message)
        try store.appendMessage(message, to: runtime.chatroom.id)
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

/// 构建角色发言上下文（internal，供单元测试）
///
/// - 各角色发言带「【角色名】」署名前缀，模型能区分发言人
/// - 合并连续同角色消息：Anthropic Messages API 要求 user/assistant 严格交替
/// - 阶段提示并入 systemPrompt，不再作为消息插入（避免产生连续 user 消息）
enum ChatRoomContextBuilder {
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

        for msg in history {
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

        // Anthropic 要求首条消息必须是 user
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
