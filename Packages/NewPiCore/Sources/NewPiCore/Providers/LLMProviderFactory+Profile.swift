import Foundation

public enum LLMProviderFactory {
    public static func anthropic(apiKeyProvider: @escaping @Sendable () async throws -> String) -> AnthropicProvider {
        AnthropicProvider(apiKeyProvider: apiKeyProvider)
    }

    public static func anthropic(resolver: CredentialResolver) -> AnthropicProvider {
        AnthropicProvider {
            try await resolver.apiKey(for: .anthropic)
        }
    }

    public static func make(
        profile: ProviderProfile,
        credentialResolver: ProviderCredentialResolver
    ) throws -> any LLMProvider {
        let apiKeyProvider: @Sendable () async throws -> String = {
            try await credentialResolver.apiKey(for: profile)
        }

        switch profile.preset {
        case .anthropic:
            let baseURL: URL
            if let baseURLString = profile.option(.baseURL),
               let url = URL(string: baseURLString) {
                baseURL = url
            } else {
                baseURL = AnthropicAPI.defaultBaseURL
            }
            let apiVersion = profile.option(.apiVersion) ?? AnthropicAPI.anthropicVersion
            return AnthropicProvider(
                apiKeyProvider: apiKeyProvider,
                baseURL: baseURL,
                apiVersion: apiVersion
            )
        case .openai, .openaiCompatible, .openRouter, .ollama:
            if profile.apiMode == .responses {
                return ResponsesAPIProvider(profile: profile, apiKeyProvider: apiKeyProvider)
            }
            return OpenAICompatibleProvider(profile: profile, apiKeyProvider: apiKeyProvider)
        }
    }
}
