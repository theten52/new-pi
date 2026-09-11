import Foundation

enum ResponsesRequestPolicy {
    private static let deepSeekMinimumMaxOutputTokens = 16_384

    static func isDeepSeekProfile(_ profile: ProviderProfile, modelID: String) -> Bool {
        let normalizedModel = modelID.lowercased()
        if normalizedModel.contains("deepseek") {
            return true
        }
        let baseURL = profile.option(.baseURL)?.lowercased() ?? ""
        return baseURL.contains("deepseek.com")
    }

    static func effectiveMaxOutputTokens(model: ModelConfig, profile: ProviderProfile) -> Int {
        guard isDeepSeekProfile(profile, modelID: model.modelID) else {
            return model.maxTokens
        }
        return max(model.maxTokens, deepSeekMinimumMaxOutputTokens)
    }

    /// 把 ThinkingLevel 映射为 Responses API 的 reasoning effort。
    /// DeepSeek V4 实测支持 none/low/medium/high（reasoning token 递增），
    /// 不再是「工具场景一刀切 none」——思考档位完全由用户配置决定。
    static func reasoningEffort(model: ModelConfig) -> String {
        switch model.thinkingLevel {
        case .off:
            "none"
        case .minimal, .low:
            "low"
        case .medium:
            "medium"
        case .high:
            "high"
        }
    }

    static func applyCommonHeaders(
        request: inout URLRequest,
        profile: ProviderProfile,
        apiKey: String
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if profile.preset.credentialRequired, !apiKey.isEmpty {
            request.setValue(profile.apiKeyHeaderValue(apiKey), forHTTPHeaderField: profile.apiKeyHeader)
        }
        if let organization = profile.option(.organization) {
            request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let referer = profile.option(.httpReferer) {
            request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }
        if let title = profile.option(.appTitle) {
            request.setValue(title, forHTTPHeaderField: "X-Title")
        }
    }
}
