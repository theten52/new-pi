import Foundation

/// 危险评估器：本地规则为主 + LLM 可选补充 + 结果缓存。
public struct DangerEvaluator: Sendable {
    public var policy: ApprovalPolicy
    /// 是否启用 LLM 补充评估（默认关闭）。
    public var llmSupplementEnabled: Bool
    public var llmAssessor: (@Sendable (String, JSONValue) async -> DangerAssessment?)?

    public init(
        policy: ApprovalPolicy = ApprovalPolicy(),
        llmSupplementEnabled: Bool = false,
        llmAssessor: (@Sendable (String, JSONValue) async -> DangerAssessment?)? = nil
    ) {
        self.policy = policy
        self.llmSupplementEnabled = llmSupplementEnabled
        self.llmAssessor = llmAssessor
    }

    /// 评估工具调用的危险等级。缓存命中直接返回，否则顺序：系统路径 → 本地规则 → 基线 → LLM（可选）。
    public func evaluate(
        toolName: String,
        arguments: JSONValue,
        cache: DangerAssessmentCache?
    ) async -> DangerAssessment {
        let fingerprint = ToolApprovalFingerprint.make(arguments: arguments)
        let key = DangerAssessmentCache.makeKey(toolName: toolName, fingerprint: fingerprint)

        if let cache, let cached = await cache.cached(key: key) {
            return cached
        }

        let assessment = await evaluateFresh(toolName: toolName, arguments: arguments)
        if let cache {
            await cache.store(key: key, assessment: assessment)
        }
        return assessment
    }

    private func evaluateFresh(toolName: String, arguments: JSONValue) async -> DangerAssessment {
        // ⓪ 写入系统敏感路径（write/edit 的目标路径）
        if let pathDanger = systemPathDangerForTool(toolName: toolName, arguments: arguments) {
            return pathDanger
        }

        // ① 本地高危规则
        if let matched = matchRiskRules(toolName: toolName, arguments: arguments) {
            return matched
        }

        // ② 工具类型基线
        let baseline = policy.baseline(for: toolName)

        // ③ LLM 补充评估（可选）：命中失败降级为基线，绝不降为 low。
        if llmSupplementEnabled, let llmAssessor {
            if let llmResult = await llmAssessor(toolName, arguments) {
                // LLM 结果与基线取较高者兜底。
                let merged = max(baseline, llmResult.level)
                return DangerAssessment(level: merged, reason: llmResult.reason ?? baselineReason(for: baseline), matchedRules: llmResult.matchedRules)
            }
        }

        return DangerAssessment(level: baseline, reason: baselineReason(for: baseline))
    }

    /// write/edit 的目标路径落在系统敏感区时，直接判为高危（确定性，不降级）。
    private func systemPathDangerForTool(toolName: String, arguments: JSONValue) -> DangerAssessment? {
        let path: String?
        switch toolName {
        case "write", "edit":
            path = arguments.objectValue?["path"]?.stringValue
        default:
            path = nil
        }
        guard let path, !path.isEmpty else { return nil }

        let lowered = path.lowercased()
        let sensitivePrefixes = [
            "/etc/", "/dev/", "/usr/", "/system/", "/sbin/", "/bin/",
            "/private/", "/library/", "/cores/", "/opt/", "/var/",
        ]
        let sensitiveFragments = [
            "/.ssh/", ".zshrc", ".bashrc", ".profile", "/etc/passwd",
            "/etc/sudoers", "/etc/hosts", "/etc/ssh/", "authorized_keys",
            "launchdaemons", "/launchagents/", "sudoers",
        ]
        if sensitivePrefixes.contains(where: { lowered.hasPrefix($0) })
            || sensitiveFragments.contains(where: { lowered.contains($0) }) {
            return DangerAssessment(
                level: .high,
                reason: "写入系统/敏感路径",
                matchedRules: ["system-sensitive-path"]
            )
        }
        return nil
    }

    private func matchRiskRules(toolName: String, arguments: JSONValue) -> DangerAssessment? {
        let commandText = extractTargetText(toolName: toolName, arguments: arguments)
        var matchedReasons: [String] = []
        var matchedRules: [String] = []
        var highestLevel: ToolDangerLevel = .low

        for rule in policy.riskRules {
            guard let regex = rule.regex else { continue }
            let range = NSRange(commandText.startIndex ..< commandText.endIndex, in: commandText)
            if regex.firstMatch(in: commandText, range: range) != nil {
                matchedReasons.append(rule.reason)
                matchedRules.append(rule.pattern)
                if rule.level > highestLevel {
                    highestLevel = rule.level
                }
            }
        }

        guard !matchedReasons.isEmpty else { return nil }
        return DangerAssessment(
            level: highestLevel,
            reason: matchedReasons.joined(separator: "；"),
            matchedRules: matchedRules
        )
    }

    private func extractTargetText(toolName: String, arguments: JSONValue) -> String {
        switch toolName {
        case "bash":
            return arguments.objectValue?["command"]?.stringValue ?? ""
        case "write", "edit":
            // 只对目标路径判规则，避免正文里出现 rm -rf/sudo 等字符串误报。
            return arguments.objectValue?["path"]?.stringValue ?? ""
        default:
            if toolName.hasPrefix(MCPToolName.prefix) {
                return String(describing: arguments)
            }
            return "\(toolName) \(String(describing: arguments))"
        }
    }

    private func baselineReason(for level: ToolDangerLevel) -> String {
        switch level {
        case .low: return "只读操作，风险较低"
        case .medium: return "可能修改文件或执行命令，需确认"
        case .high: return "极高风险操作"
        }
    }
}

/// 危险评估结果缓存（actor，LRU 上限）。
public actor DangerAssessmentCache {
    private struct Entry {
        let assessment: DangerAssessment
        let accessTime: Date
    }

    private var cache: [String: Entry] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 512) {
        self.maxEntries = maxEntries
    }

    /// 构造缓存 key：工具名 + 指纹。
    public static func makeKey(toolName: String, fingerprint: String) -> String {
        "\(toolName)#\(fingerprint)"
    }

    public func cached(key: String) -> DangerAssessment? {
        guard let entry = cache[key] else { return nil }
        cache[key] = Entry(assessment: entry.assessment, accessTime: Date())
        return entry.assessment
    }

    public func store(key: String, assessment: DangerAssessment) {
        if cache.count >= maxEntries {
            evictOldest()
        }
        cache[key] = Entry(assessment: assessment, accessTime: Date())
    }

    public func clear() {
        cache.removeAll()
    }

    private func evictOldest() {
        guard let oldest = cache.min(by: { $0.value.accessTime < $1.value.accessTime }) else { return }
        cache.removeValue(forKey: oldest.key)
    }
}
