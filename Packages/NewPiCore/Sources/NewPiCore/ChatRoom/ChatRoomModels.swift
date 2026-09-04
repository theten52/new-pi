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
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String,
        systemPrompt: String,
        icon: String = "person.fill",
        presetType: PresetRoleType? = nil,
        providerProfileID: String? = nil,
        modelID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.icon = icon
        self.presetType = presetType
        self.providerProfileID = providerProfileID
        self.modelID = modelID
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
    public var createdAt: Date
    public var updatedAt: Date
    
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
public struct ChatRoomMessage: Codable, Identifiable, Sendable {
    public var id: String
    public var chatroomID: String
    public var roleID: String          // 角色 ID（或 "user"）
    public var content: String
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
    
    public init(toolCallID: String, output: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.output = output
        self.isError = isError
    }
}
