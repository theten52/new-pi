import Foundation

public enum ProviderConnectionTester {
    public struct TestResult: Sendable, Equatable {
        public var success: Bool
        public var message: String

        public init(success: Bool, message: String) {
            self.success = success
            self.message = message
        }
    }

    /// SECURITY-REVIEW: Sends a minimal probe request to the configured provider endpoint.
    public static func test(
        profile: ProviderProfile,
        credentialResolver: ProviderCredentialResolver,
        session: URLSession = .shared
    ) async -> TestResult {
        do {
            switch profile.preset {
            case .ollama:
                return try await testOllama(profile: profile, session: session)
            case .anthropic:
                let apiKey = try await credentialResolver.apiKey(for: profile)
                return try await testAnthropic(profile: profile, apiKey: apiKey, session: session)
            case .openai, .openaiCompatible, .openRouter, .xiaomiMiMo:
                let apiKey = try await credentialResolver.apiKey(for: profile)
                if profile.apiMode == .responses {
                    return try await testResponsesAPI(profile: profile, apiKey: apiKey, session: session)
                }
                return try await testOpenAICompatible(profile: profile, apiKey: apiKey, session: session)
            }
        } catch {
            return TestResult(success: false, message: error.localizedDescription)
        }
    }

    private static func testOllama(profile: ProviderProfile, session: URLSession) async throws -> TestResult {
        let base = profile.option(.baseURL) ?? "http://127.0.0.1:11434"
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/api/tags") else {
            return TestResult(success: false, message: "Invalid Ollama base URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let (_, response) = try await session.data(for: request)
        return result(from: response, successMessage: "Ollama responded successfully.")
    }

    private static func testAnthropic(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession
    ) async throws -> TestResult {
        let baseURLString = profile.option(.baseURL) ?? AnthropicAPI.defaultBaseURL.absoluteString
        guard let url = URL(string: baseURLString) else {
            return TestResult(success: false, message: "Invalid Anthropic base URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(
            profile.option(.apiVersion) ?? AnthropicAPI.anthropicVersion,
            forHTTPHeaderField: "anthropic-version"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": profile.modelID,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        return result(from: response, successMessage: "Anthropic API accepted the request.")
    }

    private static func testResponsesAPI(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession
    ) async throws -> TestResult {
        let url = try ResponsesEndpoint.resolveURL(for: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20

        let definition = ProviderPresetCatalog.definition(for: profile.preset)
        ResponsesRequestPolicy.applyCommonHeaders(
            request: &request,
            profile: profile,
            apiKey: apiKey,
            definition: definition
        )

        let body: [String: Any] = [
            "model": profile.modelID,
            "input": "ping",
            "max_output_tokens": 16,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        return result(from: response, successMessage: "Responses API accepted the request.")
    }

    private static func testOpenAICompatible(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession
    ) async throws -> TestResult {
        let url = try OpenAICompatibleEndpoint.resolveURL(for: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let definition = ProviderPresetCatalog.definition(for: profile.preset)
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

        let body: [String: Any] = [
            "model": profile.modelID,
            "max_tokens": 1,
            "stream": false,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        return result(from: response, successMessage: "Provider accepted the request.")
    }

    private static func result(from response: URLResponse, successMessage: String) -> TestResult {
        guard let http = response as? HTTPURLResponse else {
            return TestResult(success: false, message: "Invalid response from provider.")
        }
        if (200 ... 299).contains(http.statusCode) {
            return TestResult(success: true, message: successMessage)
        }
        return TestResult(success: false, message: "Provider returned HTTP \(http.statusCode).")
    }
}
