import Foundation

enum ToolArguments {
    static func requiredString(_ arguments: JSONValue, key: String, aliases: [String] = []) throws -> String {
        for candidate in [key] + aliases {
            if let value = arguments.objectValue?[candidate]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        throw AgentError.invalidState("Missing required argument: \(key)")
    }

    static func optionalInt(_ arguments: JSONValue, key: String) -> Int? {
        guard let value = arguments.objectValue?[key] else { return nil }
        switch value {
        case let .int(number):
            return number
        case let .double(number):
            return Int(number)
        case let .string(text):
            return Int(text)
        default:
            return nil
        }
    }

    static func optionalDouble(_ arguments: JSONValue, key: String, default defaultValue: Double) -> Double {
        guard let value = arguments.objectValue?[key] else { return defaultValue }
        switch value {
        case let .double(number):
            return number
        case let .int(number):
            return Double(number)
        case let .string(text):
            return Double(text) ?? defaultValue
        default:
            return defaultValue
        }
    }
}

public struct ReadTool: AgentTool {
    public static let defaultMaxBytes = 256 * 1024

    public let name = "read"
    public let definition = ToolDefinition(
        name: "read",
        description: "Read a UTF-8 text file from the project directory.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Relative or absolute file path")]),
                "offset": .object(["type": .string("integer"), "description": .string("1-based start line")]),
                "limit": .object(["type": .string("integer"), "description": .string("Maximum number of lines to read")]),
            ]),
            "required": .array([.string("path")]),
        ])
    )

    public var maxBytes: Int

    public init(maxBytes: Int = ReadTool.defaultMaxBytes) {
        self.maxBytes = maxBytes
    }

    public func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        let path = try ToolArguments.requiredString(arguments, key: "path", aliases: ["file_path", "filePath"])
        let fileURL = try PathResolver.resolve(path, relativeTo: context.workingDirectory)
        let offset = ToolArguments.optionalInt(arguments, key: "offset")
        let limit = ToolArguments.optionalInt(arguments, key: "limit")

        NewPiLogger.debug(
            category: "tool-read",
            message: "Read tool starting",
            details: """
            path=\(path)
            resolved=\(fileURL.path)
            offset=\(offset.map(String.init) ?? "nil")
            limit=\(limit.map(String.init) ?? "nil")
            """
        )

        onUpdate?(ToolProgress(message: "Reading \(fileURL.lastPathComponent)"))

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PathResolverError.notFound(fileURL.path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AgentError.invalidState("Path is a directory: \(path)")
        }

        let data = try Data(contentsOf: fileURL)
        guard data.count <= maxBytes else {
            throw AgentError.invalidState("File exceeds max read size of \(maxBytes) bytes")
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw AgentError.invalidState("File is not valid UTF-8 text: \(path)")
        }

        let sliced = sliceLines(content, offset: offset, limit: limit)
        NewPiLogger.debug(
            category: "tool-read",
            message: "Read tool finished",
            details: "bytes=\(data.count) linesReturned=\(sliced.split(separator: "\n").count)"
        )
        return ToolResult(content: sliced)
    }

    private func sliceLines(_ content: String, offset: Int?, limit: Int?) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "", content.hasSuffix("\n") {
            lines.removeLast()
        }

        let startIndex = max((offset ?? 1) - 1, 0)
        guard startIndex < lines.count else { return "" }

        let endIndex: Int
        if let limit, limit > 0 {
            endIndex = min(startIndex + limit, lines.count)
        } else {
            endIndex = lines.count
        }

        return lines[startIndex ..< endIndex]
            .enumerated()
            .map { index, line in
                let lineNumber = startIndex + index + 1
                return "\(lineNumber)|\(line)"
            }
            .joined(separator: "\n")
    }
}

public struct WriteTool: AgentTool {
    public let name = "write"
    public let definition = ToolDefinition(
        name: "write",
        description: "Create or overwrite a UTF-8 text file in the project directory.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path"), .string("content")]),
        ])
    )

    public init() {}

    public func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        let path = try ToolArguments.requiredString(arguments, key: "path", aliases: ["file_path", "filePath"])
        let content = arguments.objectValue?["content"]?.stringValue ?? ""
        let fileURL = try PathResolver.resolve(path, relativeTo: context.workingDirectory)

        NewPiLogger.info(
            category: "tool-write",
            message: "Write tool starting",
            details: "path=\(path) resolved=\(fileURL.path) bytes=\(content.utf8.count)"
        )

        onUpdate?(ToolProgress(message: "Writing \(fileURL.lastPathComponent)"))

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let tempURL = fileURL.appendingPathExtension("new-pi.tmp")
        try content.write(to: tempURL, atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        return ToolResult(content: "Wrote \(path) (\(content.utf8.count) bytes)")
    }
}

public struct EditTool: AgentTool {
    public let name = "edit"
    public let definition = ToolDefinition(
        name: "edit",
        description: "Replace one exact occurrence of old_string with new_string in a UTF-8 text file.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "old_string": .object(["type": .string("string")]),
                "new_string": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path"), .string("old_string"), .string("new_string")]),
        ])
    )

    public var snapshotStore: EditSnapshotStore

    public init(snapshotStore: EditSnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    public func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        let path = try ToolArguments.requiredString(arguments, key: "path", aliases: ["file_path", "filePath"])
        let oldString = try ToolArguments.requiredString(arguments, key: "old_string")
        let newString = arguments.objectValue?["new_string"]?.stringValue ?? ""
        let fileURL = try PathResolver.resolve(path, relativeTo: context.workingDirectory)

        NewPiLogger.info(
            category: "tool-edit",
            message: "Edit tool starting",
            details: "path=\(path) resolved=\(fileURL.path) oldLen=\(oldString.count) newLen=\(newString.count)"
        )

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PathResolverError.notFound(fileURL.path)
        }

        onUpdate?(ToolProgress(message: "Editing \(fileURL.lastPathComponent)"))

        let original = try String(contentsOf: fileURL, encoding: .utf8)
        guard original.contains(oldString) else {
            throw AgentError.invalidState("old_string not found in \(path)")
        }

        let occurrences = original.components(separatedBy: oldString).count - 1
        guard occurrences == 1 else {
            throw AgentError.invalidState("old_string must match exactly once, found \(occurrences) matches")
        }

        let snapshotURL = try snapshotStore.snapshotBeforeEdit(sourceFile: fileURL)
        let updated = original.replacingOccurrences(of: oldString, with: newString)
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)

        return ToolResult(content: "Edited \(path). Snapshot: \(snapshotURL.lastPathComponent)")
    }
}

public struct BashTool: AgentTool {
    public static let defaultTimeoutSeconds: Double = 120
    public static let defaultMaxOutputBytes = 256 * 1024

    public let name = "bash"
    public let definition = ToolDefinition(
        name: "bash",
        description: "Run a shell command in the project working directory.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string")]),
                "timeout_seconds": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    public var timeoutSeconds: Double
    public var maxOutputBytes: Int

    public init(
        timeoutSeconds: Double = BashTool.defaultTimeoutSeconds,
        maxOutputBytes: Int = BashTool.defaultMaxOutputBytes
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
    }

    public func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        let command = try ToolArguments.requiredString(arguments, key: "command", aliases: ["cmd", "script"])
        let timeout = ToolArguments.optionalDouble(arguments, key: "timeout_seconds", default: timeoutSeconds)

        NewPiLogger.info(
            category: "tool-bash",
            message: "Bash tool starting",
            details: """
            cwd=\(context.workingDirectory.path)
            timeout=\(timeout)s
            command=\(command)
            """
        )

        onUpdate?(ToolProgress(message: "Running shell command"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = context.workingDirectory

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in context.environment {
            environment[key] = value
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutTask = Task { readPipe(stdoutPipe, maxBytes: maxOutputBytes) }
        let stderrTask = Task { readPipe(stderrPipe, maxBytes: maxOutputBytes) }

        let completedInTime = await waitForProcess(process, timeoutSeconds: timeout)
        guard completedInTime else {
            process.terminate()
            stdoutTask.cancel()
            stderrTask.cancel()
            throw AgentError.invalidState("Command timed out after \(Int(timeout)) seconds")
        }

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        let exitCode = process.terminationStatus

        var output = ""
        if !stdout.isEmpty {
            output += stdout
        }
        if !stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += "[stderr]\n\(stderr)"
        }
        if output.isEmpty {
            output = "(no output)"
        }
        output += "\n[exit \(exitCode)]"

        NewPiLogger.info(
            category: "tool-bash",
            message: exitCode == 0 ? "Bash tool finished" : "Bash tool exited non-zero",
            details: "exit=\(exitCode) output=\(NewPiLogFormat.truncate(output, maxLength: 2000))"
        )

        return ToolResult(content: output, isError: exitCode != 0)
    }

    private func waitForProcess(_ process: Process, timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continuation.resume(returning: !process.isRunning)
            }
        }
    }

    private func readPipe(_ pipe: Pipe, maxBytes: Int) -> String {
        // 增量读取：内存占用以 maxBytes 为上限（原实现 readDataToEndOfFile
        // 会先把全部输出读进内存，yes/find / 等命令可致 OOM）。
        // 注意：达到上限后仍要继续读取并丢弃，否则管道写满后子进程会阻塞。
        let handle = pipe.fileHandleForReading
        var collected = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if collected.count < maxBytes {
                let remaining = maxBytes - collected.count
                collected.append(chunk.prefix(remaining))
                if chunk.count > remaining { truncated = true }
            } else {
                truncated = true
            }
        }
        var text = String(data: collected, encoding: .utf8) ?? ""
        if truncated {
            text += "\n…[output truncated at \(maxBytes) bytes]"
        }
        return text
    }
}

public enum BuiltInTools {
    public static func codingTools(for projectDirectory: URL) -> [any AgentTool] {
        [
            ReadTool(),
            WriteTool(),
            EditTool(snapshotStore: .forProject(projectDirectory)),
            BashTool(),
        ]
    }

    public static let defaultSystemPrompt = """
    You are NewPi, a native macOS coding agent. You can read, write, and edit files and run shell commands inside the opened project directory. Prefer small, focused edits. Explain what you changed briefly after using tools.
    Always reply to the user in Simplified Chinese (简体中文), regardless of the language they write in. Use Chinese for all prose explanations, summaries, and final responses; keep code, identifiers, and technical terms in their original form.
    """
}
