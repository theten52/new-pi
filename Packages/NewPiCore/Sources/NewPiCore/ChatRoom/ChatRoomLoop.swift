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
    }
}

/// 聊天室循环 - 多模型协作的核心逻辑
@MainActor
public final class ChatRoomLoop {
    private let store: ChatRoomStore
    private let llmFactory: any ChatRoomLLMProviderFactory
    private let toolRegistry: ToolRegistry
    private let approvalHandler: ToolApprovalHandler
    
    public init(
        store: ChatRoomStore = .shared,
        llmFactory: (any ChatRoomLLMProviderFactory)? = nil,
        toolRegistry: ToolRegistry = .shared,
        approvalHandler: ToolApprovalHandler = .shared
    ) {
        self.store = store
        self.llmFactory = llmFactory ?? ChatRoomLLMProviderFactoryImpl()
        self.toolRegistry = toolRegistry
        self.approvalHandler = approvalHandler
    }
    
    // MARK: - 创建聊天室
    
    /// 创建默认聊天室（4个预设角色）
    public func createChatRoom(
        name: String,
        description: String = "",
        projectPath: String
    ) throws -> ChatRoom {
        let roles = PresetRoleType.allCases.map { ChatRoomRole.from(preset: $0) }
        let chatroom = ChatRoom(
            name: name,
            description: description,
            roles: roles,
            projectPath: projectPath
        )
        try store.save(chatroom)
        return chatroom
    }
    
    // MARK: - 阶段流转
    
    /// 进入下一阶段
    public func advancePhase(runtime: ChatRoomRuntime) throws {
        var chatroom = runtime.chatroom
        
        switch chatroom.currentPhase {
        case .discussion:
            // 讨论 → 投票（如果有多个候选方案）或 执行（如果只有一个或用户指定）
            let candidates = extractCandidates(from: runtime.messages)
            if candidates.count > 1 {
                chatroom.currentPhase = .voting
            } else {
                chatroom.currentPhase = .execution
            }
            
        case .voting:
            guard chatroom.selectedOptionID != nil else {
                throw ChatRoomError.noSelectedOption
            }
            chatroom.currentPhase = .execution
            
        case .execution:
            chatroom.currentPhase = .review
            
        case .review:
            // Review 通过 → 完成；不通过 → 执行（下一轮）
            // 这里只处理"通过"的情况，"不通过"由 reviewResult 方法处理
            chatroom.currentPhase = .completed
            
        case .completed:
            break
        }
        
        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }
    
    /// Review 结果处理
    public func handleReviewResult(runtime: ChatRoomRuntime, approved: Bool) throws {
        var chatroom = runtime.chatroom
        
        if approved {
            chatroom.currentPhase = .completed
        } else {
            guard !chatroom.isAtRoundLimit else {
                throw ChatRoomError.roundLimitReached
            }
            chatroom.reviewRoundCount += 1
            chatroom.currentPhase = .execution
        }
        
        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }
    
    // MARK: - 发言
    
    /// 触发下一个角色发言
    public func triggerNextSpeaker(runtime: ChatRoomRuntime) async throws {
        guard let speaker = runtime.currentSpeaker else {
            throw ChatRoomError.roleNotConfigured("no configured roles")
        }
        
        try await speak(role: speaker, runtime: runtime)
        
        // 推进到下一个发言者
        runtime.currentSpeakerIndex += 1
    }
    
    /// 指定角色发言
    public func triggerSpeaker(roleID: String, runtime: ChatRoomRuntime) async throws {
        guard let role = runtime.chatroom.role(by: roleID), role.isConfigured else {
            throw ChatRoomError.roleNotConfigured(roleID)
        }
        
        try await speak(role: role, runtime: runtime)
        
        // 更新当前发言索引到指定角色之后
        if let index = runtime.chatroom.configuredRoles.firstIndex(where: { $0.id == roleID }) {
            runtime.currentSpeakerIndex = index + 1
        }
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
    }
    
    // MARK: - 投票
    
    /// 用户投票
    public func userVote(optionID: String, runtime: ChatRoomRuntime) throws {
        var chatroom = runtime.chatroom
        let vote = Vote(roleID: "user", optionID: optionID)
        chatroom.votes.append(vote)
        chatroom.selectedOptionID = optionID
        chatroom.updatedAt = Date()
        try store.save(chatroom)
        runtime.chatroom = chatroom
    }
    
    // MARK: - 内部实现
    
    /// 角色发言
    private func speak(role: ChatRoomRole, runtime: ChatRoomRuntime) async throws {
        guard let providerID = role.providerProfileID,
              let modelID = role.modelID else {
            throw ChatRoomError.roleNotConfigured(role.id)
        }
        
        runtime.isRunning = true
        defer { runtime.isRunning = false }
        
        // 构建上下文
        let systemPrompt = role.systemPrompt
        let contextMessages = buildContext(
            messages: runtime.messages,
            phase: runtime.chatroom.currentPhase
        )
        
        // 创建 LLM provider
        let provider = try llmFactory.createProvider(
            profileID: providerID,
            modelID: modelID
        )
        
        // 调用 LLM
        let response = try await provider.chat(
            systemPrompt: systemPrompt,
            messages: contextMessages,
            tools: [],
            maxTokens: 4096
        )
        
        // 创建消息
        let message = ChatRoomMessage(
            chatroomID: runtime.chatroom.id,
            roleID: role.id,
            content: response.content,
            phase: runtime.chatroom.currentPhase,
            candidates: response.candidates
        )
        
        runtime.messages.append(message)
        try store.appendMessage(message, to: runtime.chatroom.id)
    }
    
    /// 构建上下文消息
    private func buildContext(messages: [ChatRoomMessage], phase: ChatRoomPhase) -> [ChatRoomLLMMessage] {
        var context: [ChatRoomLLMMessage] = []
        
        // 添加阶段提示
        let phaseHint: String
        switch phase {
        case .discussion:
            phaseHint = "当前处于【讨论阶段】。请围绕问题展开讨论，提出你的方案和建议。"
        case .voting:
            phaseHint = "当前处于【投票阶段】。请对候选方案表态。"
        case .execution:
            phaseHint = "当前处于【执行阶段】。请根据选定的方案执行。"
        case .review:
            phaseHint = "当前处于【Review 阶段】。请审查代码改动，发现问题请指出。"
        case .completed:
            phaseHint = "任务已完成。"
        }
        context.append(.system(phaseHint))
        
        // 添加历史消息
        for msg in messages {
            if msg.isUserMessage {
                context.append(.user(msg.content))
            } else {
                context.append(.assistant(msg.content))
            }
        }
        
        return context
    }
    
    /// 从消息中提取候选方案
    private func extractCandidates(from messages: [ChatRoomMessage]) -> [CandidateOption] {
        // 从最后一条有 candidates 的消息中提取
        for message in messages.reversed() {
            if let candidates = message.candidates, !candidates.isEmpty {
                return candidates
            }
        }
        return []
    }
}

// MARK: - ChatRoom LLM 相关类型

public struct ChatRoomLLMMessage: Sendable {
    public var role: ChatRoomMessageRole
    public var content: String
    
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
}

// MARK: - ChatRoom LLM Provider 协议

public protocol ChatRoomLLMProvider: Sendable {
    func chat(
        systemPrompt: String,
        messages: [ChatRoomLLMMessage],
        tools: [String],
        maxTokens: Int
    ) async throws -> ChatRoomLLMResponse
}

// MARK: - ChatRoom LLM Provider Factory Protocol

public protocol ChatRoomLLMProviderFactory: Sendable {
    func createProvider(profileID: String, modelID: String) throws -> ChatRoomLLMProvider
}

// MARK: - Tool Registry (占位)

public actor ToolRegistry {
    public static let shared = ToolRegistry()
}

// MARK: - Tool Approval Handler (占位)

public actor ToolApprovalHandler {
    public static let shared = ToolApprovalHandler()
}
