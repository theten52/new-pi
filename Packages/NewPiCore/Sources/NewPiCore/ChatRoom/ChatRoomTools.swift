import Foundation

/// 聊天室工具定义
public enum ChatRoomTools {

    /// read_file 单次读取上限（超出截断，防止撑爆共享上下文）
    static let readFileSizeLimit = 256 * 1024

    /// search_files 超时秒数：到时 kill 子进程，避免搜索卡住永久阻塞
    static let searchTimeoutSeconds: Int = 30

    /// 读取文件工具
    public static let readFile = ToolDefinition(
        name: "read_file",
        description: "读取项目中的文件内容",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("文件路径（相对于项目根目录）")
                ])
            ]),
            "required": .array([.string("path")])
        ])
    )

    /// 写入文件工具
    public static let writeFile = ToolDefinition(
        name: "write_file",
        description: "写入或创建文件",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("文件路径（相对于项目根目录）")
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("文件内容")
                ])
            ]),
            "required": .array([.string("path"), .string("content")])
        ])
    )

    /// 列出目录工具
    public static let listDirectory = ToolDefinition(
        name: "list_directory",
        description: "列出目录中的文件和子目录",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("目录路径（相对于项目根目录）")
                ])
            ]),
            "required": .array([.string("path")])
        ])
    )

    /// 搜索文件工具
    public static let searchFiles = ToolDefinition(
        name: "search_files",
        description: "在项目中搜索文件或内容",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("搜索关键词")
                ]),
                "filePattern": .object([
                    "type": .string("string"),
                    "description": .string("文件名模式（如 *.swift）")
                ])
            ]),
            "required": .array([.string("query")])
        ])
    )

    /// 获取所有工具定义
    public static func allDefinitions() -> [ToolDefinition] {
        [readFile, writeFile, listDirectory, searchFiles]
    }
}

/// 聊天室工具执行器
public actor ChatRoomToolExecutor {
    private let projectPath: String
    private let approvalManager: ChatRoomApprovalManager
    private let currentRoleID: String
    private let currentRoleName: String

    public init(
        projectPath: String,
        approvalManager: ChatRoomApprovalManager,
        roleID: String = "",
        roleName: String = ""
    ) {
        self.projectPath = projectPath
        self.approvalManager = approvalManager
        self.currentRoleID = roleID
        self.currentRoleName = roleName
    }

    /// 验证路径安全性（防止路径穿越与符号链接逃逸）
    private func validatePath(_ path: String) -> URL? {
        ChatRoomPathValidator.validate(path, projectPath: projectPath)
    }

    /// 路径校验失败的结果
    private func pathValidationError(toolCallID: String) -> ChatRoomToolResult {
        ChatRoomToolResult(
            toolCallID: toolCallID,
            output: "路径校验失败：不允许使用绝对路径或 .. 路径",
            isError: true
        )
    }

    /// 执行工具调用
    public func execute(toolCall: ToolCallContent) async throws -> ChatRoomToolResult {
        let startedAt = ContinuousClock.now
        var result: ChatRoomToolResult
        switch toolCall.name {
        case "read_file":
            result = await executeReadFile(toolCallID: toolCall.id, arguments: toolCall.arguments)
        case "write_file":
            // 写入自行计时，排除等待用户审批的时间。
            return await executeWriteFile(toolCallID: toolCall.id, arguments: toolCall.arguments)
        case "list_directory":
            result = await executeListDirectory(toolCallID: toolCall.id, arguments: toolCall.arguments)
        case "search_files":
            result = await executeSearchFiles(toolCallID: toolCall.id, arguments: toolCall.arguments)
        default:
            return ChatRoomToolResult(
                toolCallID: toolCall.id,
                output: "未知工具: \(toolCall.name)",
                isError: true
            )
        }
        result.durationSeconds = ToolExecutionTiming.seconds(since: startedAt)
        return result
    }

    /// 读取文件
    private func executeReadFile(toolCallID: String, arguments: JSONValue) async -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(path)? = args["path"] else {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "缺少 path 参数",
                isError: true
            )
        }

        // 路径安全校验
        guard let fileURL = validatePath(path) else {
            return pathValidationError(toolCallID: toolCallID)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "文件不存在: \(path)",
                isError: true
            )
        }

        do {
            let data = try Data(contentsOf: fileURL)
            if data.count > ChatRoomTools.readFileSizeLimit {
                var truncated = data.prefix(ChatRoomTools.readFileSizeLimit)
                // 回退到 UTF-8 字符边界：按字节截断可能切断多字节字符产生乱码
                while !truncated.isEmpty {
                    if String(data: truncated, encoding: .utf8) != nil { break }
                    truncated = truncated.dropLast()
                }
                let content = String(data: truncated, encoding: .utf8) ?? ""
                return ChatRoomToolResult(
                    toolCallID: toolCallID,
                    output: content + "\n\n[内容过长已截断，原始大小 \(data.count) 字节]"
                )
            }
            guard let content = String(data: data, encoding: .utf8) else {
                return ChatRoomToolResult(
                    toolCallID: toolCallID,
                    output: "文件不是 UTF-8 文本: \(path)",
                    isError: true
                )
            }
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: content
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "读取文件失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    /// 写入文件
    private func executeWriteFile(toolCallID: String, arguments: JSONValue) async -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(path)? = args["path"],
              case let .string(content)? = args["content"] else {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "缺少 path 或 content 参数",
                isError: true
            )
        }

        // 路径安全校验
        guard let fileURL = validatePath(path) else {
            return pathValidationError(toolCallID: toolCallID)
        }

        // 请求审批
        let result = await approvalManager.requestApproval(
            toolCall: ToolCallContent(id: toolCallID, name: "write_file", arguments: arguments),
            roleID: currentRoleID,
            roleName: currentRoleName
        )

        switch result {
        case .approved:
            guard !Task.isCancelled else {
                return ChatRoomToolResult(toolCallID: toolCallID, output: "写入已取消", isError: true)
            }
            break // 继续执行
        case .rejected(let reason):
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "写入被拒绝: \(reason)",
                isError: true
            )
        }

        let directory = fileURL.deletingLastPathComponent()

        let startedAt = ContinuousClock.now
        do {
            // 审批之后重新校验，拒绝等待期间新增的根外符号链接。
            guard validatePath(path) != nil else { return pathValidationError(toolCallID: toolCallID) }
            let recordedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            let before = try ToolWriteCapture.read(fileURL, replacement: content)
            if before.matches {
                return ChatRoomToolResult(toolCallID: toolCallID, output: "文件内容未变化: \(path)",
                    fileChanges: [], durationSeconds: ToolExecutionTiming.seconds(since: startedAt))
            }
            // 确保目录存在
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "文件已写入: \(path)",
                fileChanges: before.changes(path: recordedURL.path, after: content,
                    patchPath: ToolFileChange.patchPath(for: recordedURL, in: URL(fileURLWithPath: projectPath))),
                durationSeconds: ToolExecutionTiming.seconds(since: startedAt)
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "写入文件失败: \(error.localizedDescription)",
                isError: true,
                fileChanges: [],
                durationSeconds: ToolExecutionTiming.seconds(since: startedAt)
            )
        }
    }

    /// 列出目录
    private func executeListDirectory(toolCallID: String, arguments: JSONValue) async -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(path)? = args["path"] else {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "缺少 path 参数",
                isError: true
            )
        }

        // 路径安全校验
        guard let dirURL = validatePath(path) else {
            return pathValidationError(toolCallID: toolCallID)
        }

        guard FileManager.default.fileExists(atPath: dirURL.path) else {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "目录不存在: \(path)",
                isError: true
            )
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )

            var output = "目录内容:\n"
            for url in contents {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let prefix = isDir ? "📁 " : "📄 "
                output += "\(prefix)\(url.lastPathComponent)\n"
            }

            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: output
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "列出目录失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    /// 搜索文件
    private func executeSearchFiles(toolCallID: String, arguments: JSONValue) async -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(query)? = args["query"] else {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "缺少 query 参数",
                isError: true
            )
        }

        let filePattern: String?
        if case let .string(pattern)? = args["filePattern"] {
            filePattern = pattern
        } else {
            filePattern = nil
        }

        // 使用 find 命令搜索；grep -I 跳过二进制文件；
        // -prune 排除版本控制与依赖目录，避免 .git / node_modules 灌爆输出
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")

        var arguments = [
            projectPath,
            "(", "-name", ".git", "-o", "-name", "node_modules",
            "-o", "-name", ".build", "-o", "-name", "DerivedData", "-o", "-name", "Pods",
            ")",
            "-prune", "-o",
            "-type", "f",
            "-name", filePattern ?? "*",
        ]
        if !query.isEmpty {
            arguments += ["-exec", "grep", "-I", "-l", query, "{}", ";"]
        } else {
            arguments += ["-print"]
        }
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // 超时保护：到时 kill；进程死后管道关闭，readDataToEndOfFile 随之返回
            let timeoutSource = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            timeoutSource.schedule(deadline: .now() + .seconds(ChatRoomTools.searchTimeoutSeconds))
            timeoutSource.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timeoutSource.resume()
            defer { timeoutSource.cancel() }

            // 先读尽管道再等退出。反过来（先 wait）时，输出超过管道缓冲（约 64KB）
            // 会让子进程写阻塞、永不退出，waitUntilExit 永久卡死本 actor
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: data, encoding: .utf8) ?? ""

            // 被 timeout kill 的进程以信号终止
            if process.terminationReason == .uncaughtSignal {
                let partial = output.isEmpty ? "" : "\n部分结果:\n\(output)"
                return ChatRoomToolResult(
                    toolCallID: toolCallID,
                    output: "搜索超时（\(ChatRoomTools.searchTimeoutSeconds)s），已终止。\(partial)",
                    isError: true
                )
            }

            if output.isEmpty {
                return ChatRoomToolResult(
                    toolCallID: toolCallID,
                    output: "未找到匹配的文件"
                )
            }

            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "搜索结果:\n\(output)"
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: toolCallID,
                output: "搜索失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }
}

/// 工具路径校验（internal，供单元测试）
enum ChatRoomPathValidator {
    /// 拒绝绝对路径、.. 穿越，并解析符号链接确保目标在项目目录内
    static func validate(_ path: String, projectPath: String) -> URL? {
        // 拒绝绝对路径
        if path.hasPrefix("/") {
            return nil
        }

        // 拒绝包含 .. 的路径（防止路径穿越）
        if path.contains("..") {
            return nil
        }

        let fileURL = URL(fileURLWithPath: projectPath).appendingPathComponent(path)
        // standardize 不解析符号链接，这里显式 resolve，防止项目内 symlink 指向项目外
        let resolvedPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let projectRoot = URL(fileURLWithPath: projectPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        // 确保解析后的路径在项目目录内（hasPrefix 带分隔符，避免 /proj 误匹配 /proj2）
        guard resolvedPath == projectRoot || resolvedPath.hasPrefix(projectRoot + "/") else {
            return nil
        }

        return fileURL
    }
}
