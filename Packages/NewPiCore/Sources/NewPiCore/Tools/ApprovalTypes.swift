import Foundation

/// 允许粒度：一次 / 本对话一直 / 一直。
public enum ApprovalScope: String, Sendable, Equatable, Codable {
    case once      // 一次允许：仅本次调用生效
    case session   // 本对话一直允许：当前 AgentSession 生命周期内生效
    case forever   // 一直允许：跨 Session、跨 APP 启动持久化生效
}

/// 危险等级：从低到高。
public enum ToolDangerLevel: Int, Sendable, Equatable, Comparable, Codable {
    case low = 0      // 读取类
    case medium = 1   // 写入文件、常规命令
    case high = 2     // 删除、提权、磁盘操作、强制推送、下载执行等

    public static func < (lhs: ToolDangerLevel, rhs: ToolDangerLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .low: "低风险"
        case .medium: "中风险"
        case .high: "高风险"
        }
    }

    public var systemImage: String {
        switch self {
        case .low: "checkmark.circle"
        case .medium: "exclamationmark.triangle"
        case .high: "exclamationmark.triangle.fill"
        }
    }
}

/// 危险评估结果。
public struct DangerAssessment: Sendable, Equatable, Codable {
    public var level: ToolDangerLevel
    public var reason: String?
    public var matchedRules: [String]

    public init(level: ToolDangerLevel, reason: String? = nil, matchedRules: [String] = []) {
        self.level = level
        self.reason = reason
        self.matchedRules = matchedRules
    }

    public static let low = DangerAssessment(level: .low)
}

/// UI 对一次审批请求的回应：是否批准 + 允许粒度。
public struct ApprovalDecision: Sendable, Equatable {
    public var approved: Bool
    public var scope: ApprovalScope

    public init(approved: Bool, scope: ApprovalScope = .once) {
        self.approved = approved
        self.scope = scope
    }

    public static let deny = ApprovalDecision(approved: false)
    public static let allowOnce = ApprovalDecision(approved: true, scope: .once)
    public static let allowSession = ApprovalDecision(approved: true, scope: .session)
    public static let allowForever = ApprovalDecision(approved: true, scope: .forever)
}

/// 批准记录：用于本 Session 与持久化的权限记录。
public struct ApprovalRecord: Sendable, Equatable, Codable {
    public var toolName: String
    public var parametersFingerprint: String?   // nil = 整类工具
    public var scope: ApprovalScope
    public var createdAt: Date

    public init(
        toolName: String,
        parametersFingerprint: String?,
        scope: ApprovalScope,
        createdAt: Date = Date()
    ) {
        self.toolName = toolName
        self.parametersFingerprint = parametersFingerprint
        self.scope = scope
        self.createdAt = createdAt
    }

    /// 匹配工具，且指纹一致（或本记录为整类工具）。
    public func matches(toolName: String, fingerprint: String?) -> Bool {
        guard self.toolName == toolName else { return false }
        if let parametersFingerprint, let fingerprint {
            return parametersFingerprint == fingerprint
        }
        // 本记录指纹为 nil（整类）则匹配任意指纹；否则精确匹配。
        return parametersFingerprint == nil
    }
}
