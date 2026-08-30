import Foundation

public struct SubAgentTool: AgentTool {
    public static let toolName = "subagent"
    public static let defaultMaxTurns = 8

    public let name = SubAgentTool.toolName
    public let definition: ToolDefinition
    public let llm: any LLMProvider
    public let model: ModelConfig
    public let maxTurns: Int
    public let workingTools: [any AgentTool]

    public init(
        llm: any LLMProvider,
        model: ModelConfig,
        maxTurns: Int = SubAgentTool.defaultMaxTurns
    ) {
        self.llm = llm
        self.model = model
        self.maxTurns = maxTurns
        self.workingTools = [
            ReadTool(),
            BashTool(),
        ]
        self.definition = ToolDefinition(
            name: SubAgentTool.toolName,
            description: """
            Spawn a focused sub-agent to investigate or execute a delegated task in parallel. \
            The sub-agent has read and bash tools only and returns a concise summary. \
            Use for research, exploration, or parallel workstreams.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("Clear task description for the sub-agent"),
                    ]),
                    "context": .object([
                        "type": .string("string"),
                        "description": .string("Optional background context"),
                    ]),
                ]),
                "required": .array([.string("task")]),
            ])
        )
    }

    public func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        let task = try ToolArguments.requiredString(arguments, key: "task")
        let background = arguments.objectValue?["context"]?.stringValue

        var prompt = task
        if let background, !background.isEmpty {
            prompt = "Background:\n\(background)\n\nTask:\n\(task)"
        }

        onUpdate?(ToolProgress(message: "Starting sub-agent…"))

        let systemPrompt = """
        You are a focused NewPi sub-agent. Complete the assigned task using available tools, \
        then reply with a concise summary of findings or results. Do not ask follow-up questions.
        Reply in Simplified Chinese (简体中文).
        """

        let subContext = AgentContext(
            systemPrompt: systemPrompt,
            messages: [],
            workingDirectory: context.workingDirectory
        )

        let config = AgentLoopConfig(
            model: model,
            llm: llm,
            tools: workingTools,
            toolExecution: .parallel,
            // 继承主会话的审批链与危险评估：子代理的 bash 等副作用工具
            // 必须走同一套策略，不允许 .allowAll 旁路。
            toolPolicy: context.toolPolicy,
            beforeToolCall: context.beforeToolCall,
            requestToolApproval: context.requestToolApproval,
            toolApprovalTracker: context.toolApprovalTracker,
            dangerEvaluator: context.dangerEvaluator,
            dangerCache: context.dangerCache,
            auditLogger: context.auditLogger
        )

        let loop = AgentLoop()
        var finalReply = ""
        var turns = 0

        for await event in loop.run(prompt: .user(prompt), context: subContext, config: config) {
            switch event {
            case .turnStart:
                turns += 1
                if turns > maxTurns {
                    return ToolResult(
                        content: finalReply.isEmpty
                            ? "Sub-agent stopped after \(maxTurns) turns without a final reply."
                            : finalReply + "\n\n(stopped after \(maxTurns) turns)",
                        isError: true
                    )
                }
            case let .textDelta(delta):
                finalReply += delta
            case let .contextSnapshot(snapshot):
                if let last = snapshot.messages.last,
                   case let .assistant(assistant) = last,
                   assistant.stopReason == .stop,
                   !assistant.text.isEmpty {
                    finalReply = assistant.text
                }
            case let .error(error):
                return ToolResult(content: error.localizedDescription, isError: true)
            default:
                break
            }
        }

        let trimmed = finalReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ToolResult(content: "Sub-agent finished without a reply.", isError: true)
        }
        return ToolResult(content: trimmed, isError: false)
    }
}
