import Foundation

// MARK: - 阶段枚举

/// 聊天室全局阶段
public enum ChatRoomPhase: String, Codable, Sendable {
    case discussion   // 讨论阶段
    case voting       // 投票阶段
    case execution    // 执行阶段
    case review       // Review 阶段
    case completed    // 完成
}

// MARK: - 角色定义

/// 预设角色类型
public enum PresetRoleType: String, Codable, Sendable, CaseIterable {
    case architect      // 架构师
    case programmer     // 程序员
    case tester         // 测试员
    case productManager // 产品经理
    
    public var displayName: String {
        switch self {
        case .architect: "架构师"
        case .programmer: "程序员"
        case .tester: "测试员"
        case .productManager: "产品经理"
        }
    }
    
    public var icon: String {
        switch self {
        case .architect: "building.2"
        case .programmer: "desktopcomputer"
        case .tester: "checkmark.shield"
        case .productManager: "person.crop.rectangle.stack"
        }
    }
    
    public var description: String {
        switch self {
        case .architect:
            "系统设计、方案决策、技术选型"
        case .programmer:
            "代码实现、编写测试、修复 bug"
        case .tester:
            "代码审查、发现问题、验证修复"
        case .productManager:
            "需求分析、用户体验、方案评审"
        }
    }
    
    public var defaultSystemPrompt: String {
        switch self {
        case .architect:
            """
            你是一位资深架构师，负责系统设计和技术方案决策。
            - 分析需求，提出技术方案
            - 评估方案的可行性和风险
            - 指导程序员实现
            - 确保代码质量和架构合理性
            """
        case .programmer:
            """
            你是一位经验丰富的程序员，负责代码实现。
            - 根据架构师的方案编写代码
            - 使用工具读取、修改项目文件
            - 编写清晰、可维护的代码
            - 及时反馈实现中的问题
            """
        case .tester:
            """
            你是一位严谨的测试员，负责代码审查和质量保证。
            - 审查代码改动
            - 发现潜在 bug 和边界情况
            - 验证功能正确性
            - 给出明确的通过/不通过结论
            """
        case .productManager:
            """
            你是一位产品经理，负责需求分析和用户体验。
            - 确保实现符合用户需求
            - 从用户角度评估方案
            - 提出改进建议
            - 关注易用性和可访问性
            """
        }
    }
}

/// 聊天室角色
public struct ChatRoomRole: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var systemPrompt: String
    public var icon: String
    public var presetType: PresetRoleType?
    public var providerProfileID: String?  // 关联的 provider
    public var modelID: String?            // 关联的模型
    /// 角色级思考档位；nil = 跟随所绑 provider profile 的默认档位。
    public var thinkingLevel: ThinkingLevel?

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String,
        systemPrompt: String,
        icon: String = "person.fill",
        presetType: PresetRoleType? = nil,
        providerProfileID: String? = nil,
        modelID: String? = nil,
        thinkingLevel: ThinkingLevel? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.icon = icon
        self.presetType = presetType
        self.providerProfileID = providerProfileID
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
    }
    
    /// 是否已配置模型
    public var isConfigured: Bool {
        providerProfileID != nil && modelID != nil
    }
    
    /// 从预设类型创建角色
    public static func from(preset: PresetRoleType) -> ChatRoomRole {
        ChatRoomRole(
            id: preset.rawValue,
            name: preset.displayName,
            description: preset.description,
            systemPrompt: preset.defaultSystemPrompt,
            icon: preset.icon,
            presetType: preset
        )
    }
}

// MARK: - 投票

/// 候选方案
public struct CandidateOption: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var description: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        description: String
    ) {
        self.id = id
        self.title = title
        self.description = description
    }

    /// 模型输出的 JSON 只有 title/description（见设计文档决策 #16），
    /// id 缺省时自动生成，避免解码失败回退到低质量字符串解析。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.title = try container.decode(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description
    }
}

/// 投票记录
public struct Vote: Codable, Sendable, Equatable {
    public var roleID: String      // 投票角色（或 "user"）
    public var optionID: String    // 选择的方案
    
    public init(roleID: String, optionID: String) {
        self.roleID = roleID
        self.optionID = optionID
    }
}

// MARK: - 聊天室

/// 聊天室配置
public struct ChatRoom: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var roles: [ChatRoomRole]
    public var projectPath: String
    public var currentPhase: ChatRoomPhase
    public var reviewRoundCount: Int
    public var selectedOptionID: String?    // 投票选定的方案
    public var votes: [Vote]                // 投票记录
    public var currentSpeakerIndex: Int     // 当前发言者索引（断点续跑用）
    /// 第 3 轮 review 未通过时流程暂停，等待用户解锁（追加轮数）或标记完成。
    /// Optional 保证旧配置文件缺字段时可正常解码。
    public var pausedAtRoundLimit: Bool?
    /// 上下文压缩摘要检查点（决策 #7，2026-09-05 调整为自动压缩）：
    /// `compactedUpToMessageID` 之前的历史已被 `compactionSummary` 摘要替代——
    /// 仅在构建模型上下文时生效，messages.jsonl 保持完整用于展示。
    public var compactionSummary: String?
    public var compactedUpToMessageID: String?
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, description, roles, projectPath, currentPhase
        case reviewRoundCount, selectedOptionID, votes, currentSpeakerIndex
        case pausedAtRoundLimit, compactionSummary, compactedUpToMessageID
        case createdAt, updatedAt
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        roles: [ChatRoomRole] = [],
        projectPath: String,
        currentPhase: ChatRoomPhase = .discussion,
        reviewRoundCount: Int = 1,
        selectedOptionID: String? = nil,
        votes: [Vote] = [],
        currentSpeakerIndex: Int = 0,
        pausedAtRoundLimit: Bool? = nil,
        compactionSummary: String? = nil,
        compactedUpToMessageID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.roles = roles
        self.projectPath = projectPath
        self.currentPhase = currentPhase
        self.reviewRoundCount = reviewRoundCount
        self.selectedOptionID = selectedOptionID
        self.votes = votes
        self.currentSpeakerIndex = currentSpeakerIndex
        self.pausedAtRoundLimit = pausedAtRoundLimit
        self.compactionSummary = compactionSummary
        self.compactedUpToMessageID = compactedUpToMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Additive runtime fields must not make rooms created by older NewPi builds disappear.
    /// `currentSpeakerIndex` was added after the first chatroom format and is absent from
    /// those files, so decode it with the same default used by the public initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        roles = try container.decode([ChatRoomRole].self, forKey: .roles)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        currentPhase = try container.decode(ChatRoomPhase.self, forKey: .currentPhase)
        reviewRoundCount = try container.decode(Int.self, forKey: .reviewRoundCount)
        selectedOptionID = try container.decodeIfPresent(String.self, forKey: .selectedOptionID)
        votes = try container.decodeIfPresent([Vote].self, forKey: .votes) ?? []
        currentSpeakerIndex = try container.decodeIfPresent(Int.self, forKey: .currentSpeakerIndex) ?? 0
        pausedAtRoundLimit = try container.decodeIfPresent(Bool.self, forKey: .pausedAtRoundLimit)
        compactionSummary = try container.decodeIfPresent(String.self, forKey: .compactionSummary)
        compactedUpToMessageID = try container.decodeIfPresent(String.self, forKey: .compactedUpToMessageID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
    
    /// 获取已配置的角色列表
    public var configuredRoles: [ChatRoomRole] {
        roles.filter { $0.isConfigured }
    }
    
    /// 根据 ID 获取角色
    public func role(by id: String) -> ChatRoomRole? {
        roles.first { $0.id == id }
    }
    
    /// 是否可以进入下一阶段
    public var canAdvancePhase: Bool {
        switch currentPhase {
        case .discussion:
            return true
        case .voting:
            return selectedOptionID != nil
        case .execution:
            return true
        case .review:
            return true
        case .completed:
            return false
        }
    }
    
    /// 是否达到轮数上限
    public var isAtRoundLimit: Bool {
        reviewRoundCount >= 3
    }
}

// MARK: - 消息

/// 聊天室消息
/// 可选的中断标记；旧记录没有该字段，保持兼容。
public enum ChatRoomSpeechTermination: String, Codable, Sendable {
    case cancelled, failed

    public var notice: String {
        switch self {
        case .cancelled: "发言已停止：已保留部分输出及工具记录，内容未完成。停止不代表已执行的操作被撤销。"
        case .failed: "发言失败：已保留部分输出及工具记录，内容未完成。请检查实际文件状态。"
        }
    }
}

public struct ChatRoomMessage: Codable, Identifiable, Sendable {
    public var id: String
    public var chatroomID: String
    public var roleID: String          // 角色 ID（或 "user"）
    public var content: String
    /// 思考过程（extended thinking）；仅角色发言可能非空，供思考条目展示
    public var reasoningContent: String?
    /// 发言分段标识（Phase B 引擎路径）：一次发言的每个 agentic 迭代各占一条
    /// 消息、共享同一 speechID——展示层据此把各段的 Thinking/工具卡归入同一个
    /// 「处理详情」组（对齐 session 的按时间顺序交错展示）。nil = 旧格式/单条发言。
    public var speechID: String?
    public var termination: ChatRoomSpeechTermination?
    /// 本段请求使用的模型快照；旧历史缺失时保持 nil，不从角色当前配置补写。
    public var provider: String?
    public var modelID: String?
    public var phase: ChatRoomPhase
    public var candidates: [CandidateOption]?  // 讨论末尾的候选方案
    public var toolCalls: [ChatRoomToolCall]?
    public var toolResults: [ChatRoomToolResult]?
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        chatroomID: String,
        roleID: String,
        content: String,
        reasoningContent: String? = nil,
        speechID: String? = nil,
        termination: ChatRoomSpeechTermination? = nil,
        provider: String? = nil,
        modelID: String? = nil,
        phase: ChatRoomPhase,
        candidates: [CandidateOption]? = nil,
        toolCalls: [ChatRoomToolCall]? = nil,
        toolResults: [ChatRoomToolResult]? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.chatroomID = chatroomID
        self.roleID = roleID
        self.content = content
        self.reasoningContent = reasoningContent
        self.speechID = speechID
        self.termination = termination
        self.provider = provider
        self.modelID = modelID
        self.phase = phase
        self.candidates = candidates
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.timestamp = timestamp
    }
    
    /// 是否是用户消息
    public var isUserMessage: Bool {
        roleID == "user"
    }
    
    /// 是否包含候选方案
    public var hasCandidates: Bool {
        candidates != nil && !candidates!.isEmpty
    }
}

// MARK: - 工具调用（简化版，与 AgentEvent 对齐）

public struct ChatRoomToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String
    
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatRoomToolResult: Codable, Sendable, Equatable {
    public var toolCallID: String
    public var output: String
    public var isError: Bool
    /// nil = 旧历史/未知；空数组不代表 bash/MCP/子代理没有修改文件。
    public var fileChanges: [ToolFileChange]?
    public var durationSeconds: Double?
    
    public init(toolCallID: String, output: String, isError: Bool = false,
                fileChanges: [ToolFileChange]? = nil, durationSeconds: Double? = nil) {
        self.toolCallID = toolCallID
        self.output = output
        self.isError = isError
        self.fileChanges = fileChanges
        self.durationSeconds = durationSeconds
    }
}
