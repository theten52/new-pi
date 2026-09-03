import Foundation

/// 模型发现：从 provider 端点拉取可用模型列表（对应设计文档功能清单的「模型发现」）。
///
/// OpenAI 兼容 / Anthropic / Responses 均提供 `GET /models`（返回 `data[].id`），
/// Ollama 提供 `GET /api/tags`（返回 `models[].name`）。用户在 Settings 的
/// Provider 编辑页点「刷新模型列表」触发，结果合并进 profile.models。
public enum ProviderModelLister {
    public static func listModels(
        profile: ProviderProfile,
        credentialResolver: ProviderCredentialResolver,
        session: URLSession = .shared
    ) async throws -> [String] {
        let apiKey = profile.preset.credentialRequired
            ? try await credentialResolver.apiKey(for: profile)
            : ""
        return try await listModels(profile: profile, apiKey: apiKey, session: session)
    }

    /// 用显式 API Key 拉取模型列表（供模板编辑等无 profile 凭据的场景使用）。
    public static func listModels(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [String] {
        switch profile.preset {
        case .ollama:
            return try await listOllama(profile: profile, session: session)
        case .anthropic:
            return try await listAnthropic(profile: profile, apiKey: apiKey, session: session)
        case .openai, .openaiCompatible, .openRouter, .xiaomiMiMo:
            return try await listOpenAICompatible(profile: profile, apiKey: apiKey, session: session)
        }
    }

    /// 解析 `/models`（或 `/api/tags`）端点 URL。
    static func modelsEndpoint(for profile: ProviderProfile) throws -> URL {
        switch profile.preset {
        case .ollama:
            let base = profile.option(.baseURL) ?? "http://127.0.0.1:11434"
            let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(trimmed)/api/tags") else {
                throw ProviderConfigError.invalidURL(base)
            }
            return url
        case .anthropic:
            let base = profile.option(.baseURL) ?? AnthropicAPI.defaultBaseURL.absoluteString
            guard let url = URL(string: anthropicModelsRaw(from: base)) else {
                throw ProviderConfigError.invalidURL(base)
            }
            return url
        case .openai, .openaiCompatible, .openRouter, .xiaomiMiMo:
            if profile.apiMode == .responses {
                let base = profile.option(.baseURL) ?? "https://api.deepseek.com"
                let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "\(trimmed)/models") else {
                    throw ProviderConfigError.invalidURL(base)
                }
                return url
            }
            let chatURL = try OpenAICompatibleEndpoint.resolveURL(for: profile)
            let raw = chatURL.absoluteString
            let modelsRaw = raw.contains("/chat/completions")
                ? raw.replacingOccurrences(of: "/chat/completions", with: "/models")
                : raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models"
            guard let url = URL(string: modelsRaw) else {
                throw ProviderConfigError.invalidURL(modelsRaw)
            }
            return url
        }
    }

    /// Anthropic 的 base（形如 `.../v1/messages`）去掉末尾 `/messages` 换成 `/models`。
    private static func anthropicModelsRaw(from base: String) -> String {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/messages") {
            return String(trimmed.dropLast("/messages".count)) + "/models"
        }
        return trimmed + "/models"
    }

    private static func listOllama(profile: ProviderProfile, session: URLSession) async throws -> [String] {
        let url = try modelsEndpoint(for: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try parseModelIDs(from: data)
    }

    private static func listAnthropic(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession
    ) async throws -> [String] {
        let url = try modelsEndpoint(for: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(
            profile.option(.apiVersion) ?? AnthropicAPI.anthropicVersion,
            forHTTPHeaderField: "anthropic-version"
        )

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try parseModelIDs(from: data)
    }

    private static func listOpenAICompatible(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession
    ) async throws -> [String] {
        let url = try modelsEndpoint(for: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        if profile.preset.credentialRequired, !apiKey.isEmpty {
            request.setValue(profile.apiKeyHeaderValue(apiKey), forHTTPHeaderField: profile.apiKeyHeader)
        }

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try parseModelIDs(from: data)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.llmFailed("Invalid response from provider.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AgentError.llmFailed("Provider returned HTTP \(http.statusCode).")
        }
    }

    /// 解析模型列表 JSON：OpenAI 兼容 / Anthropic / Responses 为 `data[].id`，
    /// Ollama 为 `models[].name`。
    private static func parseModelIDs(from data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else { return [] }
        if let dataArray = dict["data"] as? [[String: Any]] {
            return dataArray.compactMap { $0["id"] as? String }
        }
        if let models = dict["models"] as? [[String: Any]] {
            return models.compactMap { $0["name"] as? String }
        }
        return []
    }
}
