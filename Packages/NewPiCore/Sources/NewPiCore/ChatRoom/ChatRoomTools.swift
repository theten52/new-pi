import Foundation

/// 聊天室工具定义
public enum ChatRoomTools {
    
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
    
    public init(projectPath: String) {
        self.projectPath = projectPath
    }
    
    /// 执行工具调用
    public func execute(toolCall: ToolCallContent) async throws -> ChatRoomToolResult {
        switch toolCall.name {
        case "read_file":
            return try await executeReadFile(arguments: toolCall.arguments)
        case "write_file":
            return try await executeWriteFile(arguments: toolCall.arguments)
        case "list_directory":
            return try await executeListDirectory(arguments: toolCall.arguments)
        case "search_files":
            return try await executeSearchFiles(arguments: toolCall.arguments)
        default:
            return ChatRoomToolResult(
                toolCallID: toolCall.id,
                output: "未知工具: \(toolCall.name)",
                isError: true
            )
        }
    }
    
    /// 读取文件
    private func executeReadFile(arguments: JSONValue) async throws -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(path)? = args["path"] else {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "缺少 path 参数",
                isError: true
            )
        }
        
        let fileURL = URL(fileURLWithPath: projectPath).appendingPathComponent(path)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "文件不存在: \(path)",
                isError: true
            )
        }
        
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return ChatRoomToolResult(
                toolCallID: "",
                output: content
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "读取文件失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }
    
    /// 写入文件
    private func executeWriteFile(arguments: JSONValue) async throws -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(path)? = args["path"],
              case let .string(content)? = args["content"] else {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "缺少 path 或 content 参数",
                isError: true
            )
        }
        
        let fileURL = URL(fileURLWithPath: projectPath).appendingPathComponent(path)
        let directory = fileURL.deletingLastPathComponent()
        
        do {
            // 确保目录存在
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return ChatRoomToolResult(
                toolCallID: "",
                output: "文件已写入: \(path)"
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "写入文件失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }
    
    /// 列出目录
    private func executeListDirectory(arguments: JSONValue) async throws -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(path)? = args["path"] else {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "缺少 path 参数",
                isError: true
            )
        }
        
        let dirURL = URL(fileURLWithPath: projectPath).appendingPathComponent(path)
        
        guard FileManager.default.fileExists(atPath: dirURL.path) else {
            return ChatRoomToolResult(
                toolCallID: "",
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
                toolCallID: "",
                output: output
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "列出目录失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }
    
    /// 搜索文件
    private func executeSearchFiles(arguments: JSONValue) async throws -> ChatRoomToolResult {
        guard case let .object(args) = arguments,
              case let .string(query)? = args["query"] else {
            return ChatRoomToolResult(
                toolCallID: "",
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
        
        // 使用 find 命令搜索
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        
        var arguments = [projectPath, "-name", filePattern ?? "*", "-type", "f"]
        if !query.isEmpty {
            arguments += ["-exec", "grep", "-l", query, "{}", ";"]
        }
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if output.isEmpty {
                return ChatRoomToolResult(
                    toolCallID: "",
                    output: "未找到匹配的文件"
                )
            }
            
            return ChatRoomToolResult(
                toolCallID: "",
                output: "搜索结果:\n\(output)"
            )
        } catch {
            return ChatRoomToolResult(
                toolCallID: "",
                output: "搜索失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }
}
