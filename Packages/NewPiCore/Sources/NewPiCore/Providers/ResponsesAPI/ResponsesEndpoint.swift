import Foundation

public enum ResponsesEndpoint {
    public static func resolveURL(for profile: ProviderProfile) throws -> URL {
        let raw = profile.option(.baseURL) ?? profile.preset.defaultBaseURL ?? ""

        if raw.contains("/responses") {
            guard let url = URL(string: raw) else {
                throw ProviderConfigError.invalidURL(raw)
            }
            return url
        }

        var origin = raw
            .replacingOccurrences(of: "/v1/chat/completions", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if origin.isEmpty {
            origin = "https://api.deepseek.com"
        }

        guard let url = URL(string: "\(origin)/responses") else {
            throw ProviderConfigError.invalidURL("\(origin)/responses")
        }
        return url
    }

    public static func defaultBaseURLPlaceholder(for mode: ProviderAPIMode) -> String {
        switch mode {
        case .chatCompletions:
            "https://api.example.com/v1/chat/completions"
        case .responses:
            "https://api.deepseek.com"
        }
    }
}
