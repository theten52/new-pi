import Foundation

public enum ProviderConfigError: Error, Sendable, Equatable {
    case duplicateProfileID(String)
    case emptyModelID
    case missingRequiredOption(ProviderOptionKey)
    case invalidURL(String)
    case unknownPreset(String)
    case profileNotFound(String)
    case noProfiles
}

extension ProviderConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .duplicateProfileID(id):
            "Duplicate provider profile id: \(id)"
        case .emptyModelID:
            "Model ID cannot be empty."
        case let .missingRequiredOption(key):
            "Missing required option: \(key.rawValue)"
        case let .invalidURL(value):
            "Invalid URL: \(value)"
        case let .unknownPreset(value):
            "Unknown provider preset: \(value)"
        case let .profileNotFound(id):
            "Provider profile not found: \(id)"
        case .noProfiles:
            "No provider profiles configured."
        }
    }
}

public struct ProviderProfile: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var preset: ProviderPreset
    public var modelID: String
    public var thinkingLevel: ThinkingLevel
    public var maxTokens: Int
    public var options: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        preset: ProviderPreset,
        modelID: String,
        thinkingLevel: ThinkingLevel = .off,
        maxTokens: Int = 8192,
        options: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.modelID = modelID
        self.thinkingLevel = thinkingLevel
        self.maxTokens = maxTokens
        self.options = options
    }

    public var modelConfig: ModelConfig {
        ModelConfig(
            provider: preset.rawValue,
            modelID: modelID,
            thinkingLevel: thinkingLevel,
            maxTokens: maxTokens
        )
    }

    public func option(_ key: ProviderOptionKey) -> String? {
        options[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public mutating func setOption(_ key: ProviderOptionKey, value: String?) {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            options[key.rawValue] = value
        } else {
            options.removeValue(forKey: key.rawValue)
        }
    }

    public func validate() throws {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderConfigError.emptyModelID
        }

        let definition = ProviderPresetCatalog.definition(for: preset)
        for field in definition.optionFields where field.required {
            guard option(field.key) != nil else {
                throw ProviderConfigError.missingRequiredOption(field.key)
            }
        }

        for field in definition.optionFields {
            guard let value = option(field.key) else { continue }
            if field.key == .baseURL {
                try ProviderURLValidator.validate(value, preset: preset)
            }
        }
    }

    public static func makeDefault(from template: ProviderPresetDefinition, name: String? = nil) -> ProviderProfile {
        var options: [String: String] = [:]
        for (key, value) in template.quickSetupDefaults {
            options[key.rawValue] = value
        }
        if options[ProviderOptionKey.baseURL.rawValue] == nil,
           let defaultBaseURL = template.defaultBaseURL {
            options[ProviderOptionKey.baseURL.rawValue] = defaultBaseURL
        }

        return ProviderProfile(
            id: template.preset == .anthropic ? "anthropic-default" : UUID().uuidString,
            name: name ?? template.displayName,
            preset: template.preset,
            modelID: template.defaultModels.first ?? "default",
            maxTokens: template.defaultBaseURL?.contains("deepseek.com") == true ? 16_384 : 8_192,
            options: options
        )
    }
}

public struct ProviderConfigFile: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public static let defaultAnthropicProfileID = "anthropic-default"

    public var version: Int
    public var defaultProfileID: String?
    public var profiles: [ProviderProfile]

    public init(version: Int = currentVersion, defaultProfileID: String? = nil, profiles: [ProviderProfile] = []) {
        self.version = version
        self.defaultProfileID = defaultProfileID
        self.profiles = profiles
    }

    public func defaultProfile() throws -> ProviderProfile {
        if let id = defaultProfileID, let profile = profiles.first(where: { $0.id == id }) {
            return profile
        }
        if let first = profiles.first {
            return first
        }
        throw ProviderConfigError.noProfiles
    }

    public mutating func validate() throws {
        var seen = Set<String>()
        for profile in profiles {
            if seen.contains(profile.id) {
                throw ProviderConfigError.duplicateProfileID(profile.id)
            }
            seen.insert(profile.id)
            try profile.validate()
        }
    }
}

enum ProviderURLValidator {
    static func validate(_ urlString: String, preset: ProviderPreset) throws {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw ProviderConfigError.invalidURL(urlString)
        }

        if preset == .ollama {
            let host = url.host?.lowercased() ?? ""
            guard scheme == "http", host == "127.0.0.1" || host == "localhost" else {
                throw ProviderConfigError.invalidURL("Ollama base URL must use http://127.0.0.1 or http://localhost")
            }
            return
        }

        guard scheme == "https" else {
            throw ProviderConfigError.invalidURL("Provider base URL must use HTTPS")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
