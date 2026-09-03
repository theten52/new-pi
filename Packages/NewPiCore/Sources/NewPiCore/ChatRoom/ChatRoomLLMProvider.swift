import Foundation

/// ChatRoom LLM Provider - 桥接现有 provider 系统
public struct ChatRoomLLMProviderImpl: ChatRoomLLMProvider {
    private let provider: LLMProvider
    private let modelConfig: ModelConfig
    
    public init(provider: LLMProvider, modelConfig: ModelConfig) {
        self.provider = provider
        self.modelConfig = modelConfig
    }
    
    public func chat(
        systemPrompt: String,
        messages: [ChatRoomLLMMessage],
        tools: [String],
        maxTokens: Int
    ) async throws -> ChatRoomLLMResponse {
        // 转换消息格式 - 使用现有的 AgentMessage
        let agentMessages = convertToAgentMessages(messages)
        
        // 调用 LLM
        var responseText = ""
        let stream = provider.stream(
            model: modelConfig,
            systemPrompt: systemPrompt,
            messages: agentMessages,
            tools: [] // TODO: 支持工具
        )
        
        for try await event in stream {
            switch event {
            case .textDelta(let text):
                responseText += text
            case .thinkingDelta(_):
                break
            case .thinkingSignature(_):
                break
            case .toolCall(_):
                break // TODO: 支持工具调用
            case .completed(_, _):
                break
            }
        }
        
        // 解析候选方案（如果有）
        let candidates = parseCandidates(from: responseText)
        
        return ChatRoomLLMResponse(
            content: responseText,
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
    
    /// 从响应中解析候选方案
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
    
    public init(configStore: ProviderConfigStore = ProviderConfigStore()) {
        self.configStore = configStore
    }
    
    public func createProvider(profileID: String, modelID: String) throws -> ChatRoomLLMProvider {
        let config = try configStore.load()
        guard let profile = config.profiles.first(where: { $0.id == profileID }) else {
            throw ChatRoomError.roleNotConfigured(profileID)
        }
        
        // 创建底层 provider
        let provider = try createLLMProvider(from: profile)
        let modelConfig = ModelConfig(
            provider: profile.preset.rawValue,
            modelID: modelID,
            thinkingLevel: profile.thinkingLevel,
            maxTokens: profile.effectiveMaxTokens
        )
        
        return ChatRoomLLMProviderImpl(provider: provider, modelConfig: modelConfig)
    }
    
    /// 根据 profile 创建 LLMProvider
    private func createLLMProvider(from profile: ProviderProfile) throws -> LLMProvider {
        // TODO: 桥接到现有的 provider 创建逻辑
        throw ChatRoomError.roleNotConfigured(profile.id)
    }
}
