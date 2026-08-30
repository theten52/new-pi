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

        // ①.5 只读 bash 命令：整段命令均由已知只读命令组成 → 低风险，无需审批。
        if toolName == "bash" {
            let command = ToolArguments.optionalString(arguments, key: "command", aliases: ["cmd", "script"]) ?? ""
            if Self.isReadOnlyShellCommand(command) {
                return DangerAssessment(level: .low, reason: "只读命令，风险较低")
            }
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
            // 与执行端共用别名表（path/file_path/filePath），避免别名绕过评估。
            path = ToolArguments.optionalString(arguments, key: "path", aliases: ["file_path", "filePath"])
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
        var commandText = extractTargetText(toolName: toolName, arguments: arguments)
        // 匹配前剥离 shell 字符串字面量，避免仅「提及」危险词的命令被误判为高危
        // （如 grep "sudo"、git commit -m "rm -rf 用法"）。
        if toolName == "bash" {
            commandText = Self.stripShellStringLiterals(commandText)
        }
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

    /// 剥离 shell 命令中的字符串字面量（单/双引号内容），保留引号本身。
    /// 双引号内与引号外的反斜杠转义序列整体跳过。
    static func stripShellStringLiterals(_ command: String) -> String {
        var result = ""
        result.reserveCapacity(command.count)
        var inSingle = false
        var inDouble = false
        var escaped = false
        for char in command {
            if escaped {
                escaped = false
                continue
            }
            if inSingle {
                if char == "'" { inSingle = false; result.append(char) }
                continue
            }
            if inDouble {
                if char == "\\" { escaped = true }
                if char == "\"" { inDouble = false; result.append(char) }
                continue
            }
            switch char {
            case "'": inSingle = true; result.append(char)
            case "\"": inDouble = true; result.append(char)
            case "\\": escaped = true
            default: result.append(char)
            }
        }
        return result
    }

    private func extractTargetText(toolName: String, arguments: JSONValue) -> String {
        switch toolName {
        case "bash":
            // 与执行端共用别名表（command/cmd/script），避免别名绕过评估。
            return ToolArguments.optionalString(arguments, key: "command", aliases: ["cmd", "script"]) ?? ""
        case "write", "edit":
            // 只对目标路径判规则，避免正文里出现 rm -rf/sudo 等字符串误报。
            return ToolArguments.optionalString(arguments, key: "path", aliases: ["file_path", "filePath"]) ?? ""
        default:
            if toolName.hasPrefix(MCPToolName.prefix) {
                return String(describing: arguments)
            }
            return "\(toolName) \(String(describing: arguments))"
        }
    }

    // MARK: - 只读命令识别

    /// 已知的只读命令（不含任何写入/执行子命令的形式）。
    /// 注意默认排除 awk（可 system() 执行）、xargs/tee（可执行/写入）、
    /// plutil/defaults（含写入子命令）。
    static let readOnlyCommands: Set<String> = [
        "ls", "find", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg",
        "pwd", "which", "type", "whoami", "date", "echo", "printf", "wc",
        "uniq", "tr", "cut", "file", "stat", "du", "df", "tree",
        "env", "printenv", "uname", "hostname", "basename", "dirname",
        "realpath", "readlink", "mdfind", "mdls",
    ]

    /// git 的只读子命令白名单（branch/tag/stash/config 等可写子命令不在内）。
    static let gitReadOnlySubcommands: Set<String> = [
        "status", "log", "diff", "show", "blame", "describe", "shortlog",
        "reflog", "grep", "rev-parse", "rev-list", "ls-files", "ls-tree",
        "ls-remote", "cat-file", "name-rev", "merge-base", "show-branch",
    ]

    /// 命令包装器：跳过后取真正的命令。
    static let commandWrappers: Set<String> = ["command", "builtin", "nice", "time"]

    /// find 的可写/可执行选项。
    static let findDangerousFlags: Set<String> = [
        "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprintf", "-fls", "-fprint",
    ]

    /// 判断整条 shell 命令是否只读：所有管道/序列分段的基命令都在白名单内，
    /// 且无重定向写入、无命令替换、find 无可执行选项、git 为只读子命令。
    static func isReadOnlyShellCommand(_ command: String) -> Bool {
        var text = stripShellStringLiterals(command)
        // 去掉写入 /dev/null 的重定向与 fd 复制（2>/dev/null、2>&1 等），无副作用。
        text = text.replacingOccurrences(of: #"(&|[0-9])?>>?\s*/dev/null"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[0-9]?>&[0-9]"#, with: " ", options: .regularExpression)
        // 仍有写入重定向 / 命令替换 / 进程替换 → 无法静态证明只读。
        if text.contains(">") || text.contains("$(") || text.contains("`")
            || text.contains("<(") || text.contains(">(") {
            return false
        }
        // 统一分隔符后拆分管道/序列分段。
        let normalized = text
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
        let segments = normalized.split(whereSeparator: { $0 == "|" || $0 == ";" || $0 == "&" || $0 == "\n" })
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { isReadOnlySegment(String($0)) }
    }

    private static func isReadOnlySegment(_ segment: String) -> Bool {
        var tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // 跳过前导环境变量赋值（FOO=bar cmd）。
        while let first = tokens.first,
              first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="# , options: .regularExpression) != nil {
            tokens.removeFirst()
        }
        // 跳过包装器（command/nice/time 等）。
        while let first = tokens.first, commandWrappers.contains(first) {
            tokens.removeFirst()
        }
        guard let base = tokens.first else { return false }
        let baseName = base.split(separator: "/").last.map(String.init) ?? base

        switch baseName {
        case "git":
            // 第一个非 flag 参数视为子命令；`git -C dir status` 这类带参数 flag
            // 无法精确解析时保守返回 false（按基线 medium 处理）。
            guard let subcommand = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
                return false
            }
            return gitReadOnlySubcommands.contains(subcommand)
        case "find":
            return !tokens.contains { findDangerousFlags.contains($0) }
        case "sed":
            // sed -i 原地写文件；不带 -i 为只读。
            return !tokens.contains { $0 == "-i" || $0.hasPrefix("-i") }
        case "sort":
            // sort -o file 写文件；不带 -o 为只读。
            return !tokens.contains { $0 == "-o" || $0.hasPrefix("-o") }
        case "env":
            // `env` 单独使用是只读；`env FOO=x cmd` 实际执行 cmd，不判只读。
            return tokens.count == 1
        default:
            return readOnlyCommands.contains(baseName)
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
