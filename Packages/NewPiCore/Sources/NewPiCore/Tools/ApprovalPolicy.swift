import Foundation

/// 单条危险规则。
public struct ApprovalRiskRule: Sendable, Equatable, Codable {
    public var pattern: String
    public var reason: String
    public var level: ToolDangerLevel

    public init(pattern: String, reason: String, level: ToolDangerLevel = .high) {
        self.pattern = pattern
        self.reason = reason
        self.level = level
    }

    public var regex: NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}

/// 危险评估规则集（可持久化配置）。
public struct ApprovalPolicy: Sendable, Equatable, Codable {
    public var riskRules: [ApprovalRiskRule]
    /// 各工具类型的基线危险等级（未命中规则时的默认等级）。
    public var toolBaseline: [String: ToolDangerLevel]
    /// 是否启用 LLM 补充评估（本地规则命中时仍优先、永不降级）。
    public var llmSupplementEnabled: Bool

    public init(
        riskRules: [ApprovalRiskRule] = ApprovalPolicy.defaultRiskRules,
        toolBaseline: [String: ToolDangerLevel] = ApprovalPolicy.defaultToolBaseline,
        llmSupplementEnabled: Bool = false
    ) {
        self.riskRules = riskRules
        self.toolBaseline = toolBaseline
        self.llmSupplementEnabled = llmSupplementEnabled
    }

    /// 兼容旧 JSON：缺失字段时回退默认值（尤其是新增的 llmSupplementEnabled）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        riskRules = try container.decodeIfPresent([ApprovalRiskRule].self, forKey: .riskRules) ?? ApprovalPolicy.defaultRiskRules
        toolBaseline = try container.decodeIfPresent([String: ToolDangerLevel].self, forKey: .toolBaseline) ?? ApprovalPolicy.defaultToolBaseline
        llmSupplementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmSupplementEnabled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case riskRules
        case toolBaseline
        case llmSupplementEnabled
    }

    /// 覆盖常见 `rm` 变体：合并参数、分离参数、`--recursive/--force` 组合。
    public static let defaultRiskRules: [ApprovalRiskRule] = [
        ApprovalRiskRule(pattern: #"(?i)\brm\s+(-rf|-fr|-rfv|-rvf|-r\s+-\s*f|-f\s+-\s*r|--recursive\s+--force|--force\s+--recursive)\b"#, reason: "递归强制删除文件"),
        ApprovalRiskRule(pattern: #"(?i)\brm\s+-[a-z]*[rR][a-z]*\s+/+\s*\$"#, reason: "删除根目录"),
        ApprovalRiskRule(pattern: #"(?i)\bsudo\b"#, reason: "提权执行"),
        ApprovalRiskRule(pattern: #"(?i)\b(mkfs|diskutil|dd)\b"#, reason: "磁盘/设备操作"),
        ApprovalRiskRule(pattern: #"(?i)\bgit\s+push\s+--force\b"#, reason: "强制推送 git"),
        ApprovalRiskRule(pattern: #"(?i)curl\s+.*\|+\s*(sh|bash)"#, reason: "下载并执行脚本"),
        ApprovalRiskRule(pattern: #"(?i)\bchmod\s+777\b"#, reason: "权限放宽为 777"),
        ApprovalRiskRule(pattern: #"(?i)>\s*/etc/passwd|>\s*/dev/(disk|[a-z]+)"#, reason: "写入系统/设备路径"),
        ApprovalRiskRule(pattern: #"(?i)\bshutdown|reboot|halt\b"#, reason: "关机/重启系统"),
        ApprovalRiskRule(pattern: #"(?i)\bkubectl\s+delete\b"#, reason: "删除 k8s 资源"),
        ApprovalRiskRule(pattern: #"(?i)\bdocker\s+(rm|rmi|system\s+prune)\b"#, reason: "删除 docker 资源"),
        ApprovalRiskRule(pattern: #"(?i)\baws\s+\w+\s+delete\b"#, reason: "删除云资源"),
        ApprovalRiskRule(pattern: #"(?i)>+\s*~?/\.ssh/|>\s*~?/\.?ssh/"#, reason: "写入 SSH 配置"),
        ApprovalRiskRule(pattern: #"(?i)>+\s*~?/\.zshrc|\.bashrc|\.profile"#, reason: "写入 shell 启动配置"),
    ]

    public static let defaultToolBaseline: [String: ToolDangerLevel] = [
        "read": .low,
        "write": .medium,
        "edit": .medium,
        "bash": .medium,
        "subagent": .medium,
    ]

    public func baseline(for toolName: String) -> ToolDangerLevel {
        if toolName.hasPrefix(MCPToolName.prefix) {
            // MCP 工具默认中风险，命中规则则升级。
            return .medium
        }
        return toolBaseline[toolName] ?? .medium
    }
}
