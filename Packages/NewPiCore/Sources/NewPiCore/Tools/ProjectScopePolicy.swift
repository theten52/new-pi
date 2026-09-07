import Foundation

/// 项目根内文件操作免审批判定（PROJECT-SCOPE-AUTO-APPROVE）。
///
/// 需求：项目/聊天室根路径下的文件修改（含删除）不需要权限提示。
///
/// 设计边界：
/// - `write`/`edit` 的执行端本就被 PathResolver 硬沙箱在项目根内（越界直接报错），
///   审批层只是放开弹窗，无新增执行风险。
/// - `bash` 通过静态分析放行「所有路径参数都可证明落在项目根内」的已知文件操作
///   （rm/mv/cp/mkdir/sed -i/重定向写入等）；证明不了就照常弹窗。
///   放行的基命令 = 文件操作白名单 ∪ 只读命令白名单（只读命令仅在输出重定向
///   目标也在项目根内时放行，如 `echo x > build/out.txt`）。
/// - 高危规则（sudo、git push --force、写系统路径等）在进入本策略前已由
///   DangerEvaluator 拦截判为 high，AgentLoop 侧不对 high 咨询本策略，永不降级。
/// - 项目根过宽（home、home 的祖先如 /Users、系统目录）时功能整体失效退回弹窗，
///   防止误选宽根导致全盘免审。
/// - MCP 工具与 subagent 调用本身不在此策略范围（照常弹窗）；subagent 通过
///   ToolContext 继承同一策略，其内部的文件工具行为与主会话一致。
public struct ProjectScopePolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        /// 在项目根内，可免审批执行。
        case allow(reason: String)
        /// 无法证明在项目根内，走正常审批弹窗流程。
        case prompt
    }

    /// 符号链接解析 + 标准化后的项目根。
    public let root: URL
    /// 是否启用。init 时若根过宽会自动置 false（PROJECT-SUBROOT-GUARD）。
    public let isEnabled: Bool

    public init(root: URL, isEnabled: Bool = true, homeDirectory: URL? = nil) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = resolved
        self.isEnabled = isEnabled && !Self.isRootTooWide(resolved, homeDirectory: homeDirectory)
    }

    /// 判定一次工具调用是否可凭「项目内」免审批。
    /// 仅处理 write/edit/bash；MCP、subagent 等一律 prompt。
    public func authorize(toolName: String, arguments: JSONValue) -> Verdict {
        guard isEnabled else { return .prompt }
        switch toolName {
        case "write", "edit":
            return authorizeDirectPath(arguments)
        case "bash":
            guard let command = ToolArguments.optionalString(
                arguments,
                key: "command",
                aliases: ["cmd", "script"]
            ), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .prompt
            }
            return authorizeCommand(command)
        default:
            return .prompt
        }
    }

    // MARK: - 根过宽保护

    /// 系统敏感目录前缀（与 DangerEvaluator.systemPathDangerForTool 的敏感前缀对齐）。
    private static let systemSensitivePrefixes = [
        "/etc", "/dev", "/usr", "/system", "/sbin", "/bin",
        "/private", "/library", "/cores", "/opt", "/var",
    ]

    /// 根为 home、home 的祖先（/Users、/）或贴近系统敏感目录时视为过宽。
    /// 过宽根下的「项目内放行」等于对全盘免审，功能自动退回弹窗。
    /// 系统目录下的深层路径（如 /private/var/folders/xx/…/T/project，macOS 临时
    /// 目录与沙箱位置）距系统目录超过 2 层，不算过宽，否则临时目录里的项目永远失效。
    public static func isRootTooWide(_ resolvedRoot: URL, homeDirectory: URL? = nil) -> Bool {
        let rootPath = resolvedRoot.path
        if rootPath == "/" {
            return true
        }
        let home = (homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.path
        // root == home 或 root 是 home 的祖先（homePath 以 rootPath 开头）。
        if rootPath == homePath || homePath.hasPrefix(rootPath + "/") {
            return true
        }
        for prefix in systemSensitivePrefixes
        where rootPath == prefix || rootPath.hasPrefix(prefix + "/") {
            let remainder = rootPath.dropFirst(prefix.count).drop(while: { $0 == "/" })
            if remainder.split(separator: "/").count <= 2 {
                return true
            }
        }
        return false
    }

    // MARK: - write/edit

    /// write/edit：目标路径（与执行端共用别名表）解析后在项目根内即放行。
    private func authorizeDirectPath(_ arguments: JSONValue) -> Verdict {
        guard let path = ToolArguments.optionalString(
            arguments,
            key: "path",
            aliases: ["file_path", "filePath"]
        ), !path.isEmpty, isInsideProjectRoot(path) else {
            return .prompt
        }
        return .allow(reason: "目标路径在项目根内")
    }

    // MARK: - bash 静态分析

    /// 本策略放行的文件修改命令（均为「参数即路径」语义）。
    /// 不含 find/-exec 类可执行任意命令的工具、不含 tar/unzip（条目路径不可控）。
    static let fileModificationCommands: Set<String> = [
        "rm", "mv", "cp", "ln", "mkdir", "rmdir", "touch", "chmod", "sed", "tee", "sort",
    ]

    /// bash 分段包装器（在 DangerEvaluator.commandWrappers 基础上补 exec）。
    static let segmentWrappers: Set<String> = ["command", "builtin", "nice", "time", "exec"]

    /// 分析整条 bash 命令：
    /// 1. 剥离字符串字面量后，命令替换/进程替换无法静态分析 → prompt；
    /// 2. 去掉无副作用的 /dev/null 重定向与 fd 复制；
    /// 3. 剩余输出重定向（>、>>）目标必须在项目根内（`<` 输入重定向只读不限制）；
    /// 4. 各分段基命令在白名单内，且所有非 flag 参数（即路径）都在项目根内。
    func authorizeCommand(_ command: String) -> Verdict {
        var text = DangerEvaluator.stripShellStringLiterals(command)

        if text.contains("$(") || text.contains("`") || text.contains("<(") || text.contains(">(") {
            return .prompt
        }

        // /dev/null 与 fd 复制（2>/dev/null、2>&1、>&2 等）无文件写入副作用。
        text = text.replacingOccurrences(
            of: #"(&|[0-9])?>>?\s*/dev/null"#,
            with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"[0-9]?(>>?&|&>>?)\s*[0-9]+"#,
            with: " ", options: .regularExpression
        )

        // 剩余输出重定向：逐个取出目标校验；`<` 输入只读不校验。
        if let regex = try? NSRegularExpression(pattern: #"(?:^|[\s;&|(])(?:[0-9]&|&|[0-9])?(>>?)\s*([^\s;&|<>`]+)"#) {
            let full = NSRange(text.startIndex..., in: text)
            var targets: [String] = []
            var ranges: [NSRange] = []
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match, let targetRange = Range(match.range(at: 2), in: text) else { return }
                targets.append(String(text[targetRange]))
                ranges.append(match.range)
            }
            for (target, range) in zip(targets, ranges) {
                guard isInsideProjectRoot(target) else { return .prompt }
                if let swiftRange = Range(range, in: text) {
                    text = text.replacingCharacters(in: swiftRange, with: " ")
                }
            }
        }

        // 仍有未识别的输出重定向形态 → 保守弹窗。
        if text.contains(">") {
            return .prompt
        }

        var normalized = text
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
        let segments = normalized.split(whereSeparator: { $0 == "|" || $0 == ";" || $0 == "&" || $0 == "\n" })
        guard !segments.isEmpty else { return .prompt }
        for segment in segments {
            if case .prompt = authorizeSegment(String(segment)) {
                return .prompt
            }
        }
        return .allow(reason: "文件操作目标均在项目根内")
    }

    /// 单分段：跳过环境变量赋值与包装器后，基命令必须在白名单内，
    /// 且所有非 flag 参数（即路径参数）都落在项目根内。
    private func authorizeSegment(_ segment: String) -> Verdict {
        var tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // 前导环境变量赋值（FOO=bar cmd）。
        while let first = tokens.first,
              first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            tokens.removeFirst()
        }
        // 包装器（command/nice/time/exec 等）。
        while let first = tokens.first, Self.segmentWrappers.contains(first) {
            tokens.removeFirst()
        }
        guard let baseRaw = tokens.first else { return .prompt }
        tokens.removeFirst()
        let base = baseRaw.split(separator: "/").last.map(String.init) ?? baseRaw
        guard Self.isAllowedBaseCommand(base, arguments: tokens) else { return .prompt }

        // `--` 之后所有 token 都是路径参数。
        var sawDoubleDash = false
        for token in tokens {
            if !sawDoubleDash {
                if token == "--" {
                    sawDoubleDash = true
                    continue
                }
                if token.hasPrefix("-") { continue }
            }
            guard isInsideProjectRoot(token) else { return .prompt }
        }
        return .allow(reason: "路径均在项目根内")
    }

    /// 基命令白名单：文件修改命令直接放行；只读命令放行（find 需无危险 flag、
    /// git 需只读子命令、env 排除——`env FOO=1 cmd` 可借道执行任意命令）。
    static func isAllowedBaseCommand(_ base: String, arguments: [String]) -> Bool {
        if fileModificationCommands.contains(base) {
            return true
        }
        guard !DangerEvaluator.readOnlyCommands.contains(base) else {
            if base == "find" {
                return !arguments.contains { DangerEvaluator.findDangerousFlags.contains($0) }
            }
            return base != "env"
        }
        if base == "git" {
            guard let subcommand = arguments.first(where: { !$0.hasPrefix("-") }) else {
                return false
            }
            return DangerEvaluator.gitReadOnlySubcommands.contains(subcommand)
        }
        return false
    }

    // MARK: - 路径围栏

    /// token 解析后（剥引号、~ 展开、相对路径拼接、符号链接解析）是否落在项目根内。
    /// 含变量/命令替换的 token 无法静态分析，一律视为在根外（→ prompt）。
    func isInsideProjectRoot(_ rawToken: String) -> Bool {
        var token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !token.isEmpty else { return true } // 空参数（如 sed -i ''）不指向文件系统
        guard !token.contains("$"), !token.contains("`") else { return false }

        let expanded = (token as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else {
            candidate = root.appendingPathComponent(expanded)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        return resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/")
    }
}
