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
        messages: [ChatRoomLLMMessage],
        tools: [String],
        maxTokens: Int
    ) async throws -> ChatRoomLLMResponse {
        // 转换消息格式
        var agentMessages = convertToAgentMessages(messages)
        
        // 获取工具定义
        let toolDefinitions = ChatRoomTools.allDefinitions()
        
        // agentic loop：支持多轮工具调用
        var finalResponseText = ""
        var allToolCalls: [ToolCallContent] = []
        var allToolResults: [ChatRoomToolResult] = []
        var iteration = 0
        let maxIterations = 10 // 防止无限循环
        
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
                case .thinkingDelta(_):
                    break
                case .thinkingSignature(_):
                    break
                case .toolCall(let toolCall):
                    hasToolCalls = true
                    toolCalls.append(toolCall)
                case .completed(_, _):
                    break
                }
            }
            
            // 如果没有工具调用，返回结果
            if !hasToolCalls {
                finalResponseText = responseText
                break
            }
            
            // 执行工具调用并收集结果
            allToolCalls.append(contentsOf: toolCalls)
            
            // 添加助手消息（包含工具调用）
            agentMessages.append(.assistant(AssistantMessage(
                text: responseText,
                provider: "chatroom",
                modelID: modelConfig.modelID,
                stopReason: .toolUse
            )))
            
            // 执行每个工具调用
            for toolCall in toolCalls {
                let result = try await toolExecutor.execute(toolCall: toolCall)
                allToolResults.append(result)
                
                // 添加工具结果消息
                agentMessages.append(.toolResult(ToolResultMessage(
                    toolCallID: toolCall.id,
                    toolName: toolCall.name,
                    content: result.output,
                    isError: result.isError
                )))
            }
            
            // 如果没有文本响应但有工具调用，继续循环
            if responseText.isEmpty {
                continue
            }
            
            // 保存中间响应
            finalResponseText = responseText
        }
        
        // 解析候选方案（JSON 格式）
        let candidates = parseCandidatesJSON(from: finalResponseText)
        
        return ChatRoomLLMResponse(
            content: finalResponseText,
            candidates: candidates
        )
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
    
    /// 解析候选方案（JSON 格式）
    private func parseCandidatesJSON(from text: String) -> [CandidateOption]? {
        // 尝试从文本中提取 JSON 格式的候选方案
        // 格式：```json\n[{"title": "...", "description": "..."}, ...]\n```
        
        guard let jsonStart = text.range(of: "```json"),
              let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) else {
            // 回退到字符串解析
            return parseCandidates(from: text)
        }
        
        let jsonStr = String(text[jsonStart.upperBound..<jsonEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let jsonData = jsonStr.data(using: .utf8) else {
            return parseCandidates(from: text)
        }
        
        do {
            let candidates = try JSONDecoder().decode([CandidateOption].self, from: jsonData)
            return candidates.isEmpty ? nil : candidates
        } catch {
            // JSON 解析失败，回退到字符串解析
            return parseCandidates(from: text)
        }
    }
    
    /// 回退的字符串解析
    private func parseCandidates(from text: String) -> [CandidateOption]? {
        var candidates: [CandidateOption] = []
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("方案") || trimmed.hasPrefix("选项") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let title = parts[0].trimmingCharacters(in: .whitespaces)
                    let description = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    candidates.append(CandidateOption(title: title, description: description))
                }
            }
        }
        
        return candidates.isEmpty ? nil : candidates
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
    
    public func createProvider(profileID: String, modelID: String, projectPath: String) throws -> ChatRoomLLMProvider {
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
            approvalManager: approvalManager
        )
        
        return ChatRoomLLMProviderImpl(provider: provider, modelConfig: modelConfig, toolExecutor: toolExecutor)
    }
}
