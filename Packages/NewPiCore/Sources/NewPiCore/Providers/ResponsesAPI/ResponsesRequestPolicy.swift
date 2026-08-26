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

    static func reasoningEffort(model: ModelConfig, profile: ProviderProfile, hasTools: Bool) -> String {
        if isDeepSeekProfile(profile, modelID: model.modelID), hasTools {
            return "none"
        }

        switch model.thinkingLevel {
        case .off:
            return "none"
        case .minimal, .low:
            return "low"
        case .medium, .high:
            return "high"
        }
    }

    static func applyCommonHeaders(
        request: inout URLRequest,
        profile: ProviderProfile,
        apiKey: String,
        definition: ProviderPresetDefinition
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if definition.credentialRequired, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
