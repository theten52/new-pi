import Foundation

/// ChatRoom LLM Provider - 桥接现有 provider 系统
public struct ChatRoomLLMProviderImpl: ChatRoomLLMProvider {
    private let provider: LLMProvider
    private let modelConfig: ModelConfig
    private let toolExecutor: ChatRoomToolExecutor

    public init(provider: LLMProvider, modelConfig: ModelConfig, toolExecutor: ChatRoomToolExecutor) {
        self.provider = provider
        self.modelConfig = modelConfig
        self.toolExecutor = toolExecutor
    }

    public func chat(
        systemPrompt: String,
        messages: [ChatRoomLLMMessage]
    ) async throws -> ChatRoomLLMResponse {
        // 转换消息格式
        var agentMessages = convertToAgentMessages(messages)

        // 所有阶段都可以使用所有工具（决策 #15）
        let toolDefinitions = ChatRoomTools.allDefinitions()

        // agentic loop（决策 #14）：工具结果回传给模型继续，最多 10 轮
        var finalResponseText = ""
        var allToolCalls: [ToolCallContent] = []
        var allToolResults: [ChatRoomToolResult] = []
        var iteration = 0
        let maxIterations = 10

        while iteration < maxIterations {
            iteration += 1

            // 调用 LLM
            var responseText = ""
            var toolCalls: [ToolCallContent] = []
            var hasToolCalls = false

            let stream = provider.stream(
                model: modelConfig,
                systemPrompt: systemPrompt,
                messages: agentMessages,
                tools: toolDefinitions
            )

            for try await event in stream {
                switch event {
                case .textDelta(let text):
                    responseText += text
                case .thinkingDelta, .thinkingSignature:
                    break
                case .toolCall(let toolCall):
                    hasToolCalls = true
                    toolCalls.append(toolCall)
                case .completed:
                    break
                }
            }

            // 如果没有工具调用，返回结果
            if !hasToolCalls {
                finalResponseText = responseText
                break
            }

            allToolCalls.append(contentsOf: toolCalls)

            // 添加助手消息（包含工具调用）
            agentMessages.append(.assistant(AssistantMessage(
                text: responseText,
                toolCalls: toolCalls,
                provider: "chatroom",
                modelID: modelConfig.modelID,
                stopReason: .toolUse
            )))

            // 执行每个工具调用并把结果回传
            for toolCall in toolCalls {
                let result = try await toolExecutor.execute(toolCall: toolCall)
                allToolResults.append(result)

                agentMessages.append(.toolResult(ToolResultMessage(
                    toolCallID: toolCall.id,
                    toolName: toolCall.name,
                    content: result.output,
                    isError: result.isError
                )))
            }

            // 保存中间响应（后续迭代有最终文本时会覆盖）
            finalResponseText = responseText
        }

        // 达到轮数上限仍未产出文本：向用户说明，而不是静默返回空消息
        if finalResponseText.isEmpty, !allToolCalls.isEmpty {
            finalResponseText = "（工具调用达到 \(maxIterations) 轮上限，未产出最终回复）"
        }

        // 解析候选方案（决策 #16：JSON 优先，回退字符串）
        let candidates = ChatRoomCandidateParser.parse(from: finalResponseText)

        return ChatRoomLLMResponse(
            content: finalResponseText,
            candidates: candidates,
            toolCalls: allToolCalls.map { call in
                ChatRoomToolCall(
                    id: call.id,
                    name: call.name,
                    arguments: Self.argumentsString(call.arguments)
                )
            },
            toolResults: allToolResults
        )
    }

    /// 工具参数序列化为可读 JSON 字符串（落盘/展示用）
    static func argumentsString(_ value: JSONValue) -> String {
        guard let object = try? value.toJSONObject(),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// 转换消息格式
    private func convertToAgentMessages(_ messages: [ChatRoomLLMMessage]) -> [AgentMessage] {
        messages.map { msg in
            switch msg.role {
            case .system, .user:
                return .user(UserMessage(content: msg.content))
            case .assistant:
                return .assistant(AssistantMessage(
                    text: msg.content,
                    provider: "chatroom",
                    modelID: modelConfig.modelID,
                    stopReason: .stop
                ))
            }
        }
    }
}

/// 候选方案解析（决策 #16）：```json 代码块优先，回退到「方案/选项」行解析
public enum ChatRoomCandidateParser {
    public static func parse(from text: String) -> [CandidateOption]? {
        if let jsonCandidates = parseJSONBlock(from: text) {
            return jsonCandidates
        }
        return parsePlainLines(from: text)
    }

    /// 从 ```json ... ``` 代码块解析候选方案数组
    private static func parseJSONBlock(from text: String) -> [CandidateOption]? {
        guard let jsonStart = text.range(of: "```json"),
              let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) else {
            return nil
        }

        let jsonStr = String(text[jsonStart.upperBound..<jsonEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = jsonStr.data(using: .utf8) else { return nil }

        do {
            let candidates = try JSONDecoder().decode([CandidateOption].self, from: jsonData)
            return candidates.isEmpty ? nil : candidates
        } catch {
            return nil
        }
    }

    /// 回退：解析「方案A: 描述」行（兼容全角冒号）。
    /// 要求至少两条：讨论中单条「方案X:」的普通提及很常见，两条枚举更像归纳。
    private static func parsePlainLines(from text: String) -> [CandidateOption]? {
        var candidates: [CandidateOption] = []
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("方案") || trimmed.hasPrefix("选项") {
                let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ":："))
                if parts.count >= 2 {
                    let title = parts[0].trimmingCharacters(in: .whitespaces)
                    let description = parts[1...].joined(separator: "：").trimmingCharacters(in: .whitespaces)
                    candidates.append(CandidateOption(title: title, description: description))
                }
            }
        }

        return candidates.count >= 2 ? candidates : nil
    }
}

/// ChatRoom LLM Provider Factory 实现
public final class ChatRoomLLMProviderFactoryImpl: ChatRoomLLMProviderFactory, @unchecked Sendable {
    private let configStore: ProviderConfigStore
    private let credentialResolver: ProviderCredentialResolver
    private let approvalManager: ChatRoomApprovalManager

    public init(
        configStore: ProviderConfigStore = ProviderConfigStore(),
        credentialResolver: ProviderCredentialResolver = ProviderCredentialResolver.makeDefault(),
        approvalManager: ChatRoomApprovalManager = ChatRoomApprovalManager()
    ) {
        self.configStore = configStore
        self.credentialResolver = credentialResolver
        self.approvalManager = approvalManager
    }

    public func createProvider(
        profileID: String,
        modelID: String,
        projectPath: String,
        roleID: String,
        roleName: String
    ) throws -> ChatRoomLLMProvider {
        let config = try configStore.load()
        guard let profile = config.profiles.first(where: { $0.id == profileID }) else {
            throw ChatRoomError.roleNotConfigured(profileID)
        }

        // 创建底层 provider
        let provider = try LLMProviderFactory.make(
            profile: profile,
            credentialResolver: credentialResolver
        )

        let modelConfig = ModelConfig(
            provider: profile.preset.rawValue,
            modelID: modelID,
            thinkingLevel: profile.thinkingLevel,
            maxTokens: profile.effectiveMaxTokens
        )

        let toolExecutor = ChatRoomToolExecutor(
            projectPath: projectPath,
            approvalManager: approvalManager,
            roleID: roleID,
            roleName: roleName
        )

        return ChatRoomLLMProviderImpl(provider: provider, modelConfig: modelConfig, toolExecutor: toolExecutor)
    }
}
