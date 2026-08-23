import Foundation

public struct ProviderConfigStore {
    public var configURL: URL
    public var credentialResolver: ProviderCredentialResolver

    public init(
        configURL: URL = NewPiConfig.defaultAgentDirectory.appendingPathComponent("providers.json"),
        credentialResolver: ProviderCredentialResolver = ProviderCredentialResolver()
    ) {
        self.configURL = configURL
        self.credentialResolver = credentialResolver
    }

    public func load() throws -> ProviderConfigFile {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            let config = try decoder.decode(ProviderConfigFile.self, from: data)
            var validated = config
            try validated.validate()
            return validated
        }

        try credentialResolver.migrateLegacyAnthropicKeyIfNeeded()
        let defaultConfig = Self.bootstrapDefaultConfig()
        try save(defaultConfig)
        return defaultConfig
    }

    public func save(_ config: ProviderConfigFile) throws {
        var validated = config
        try validated.validate()

        let fileManager = FileManager.default
        let directory = configURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated)
        try data.write(to: configURL, options: .atomic)
    }

    public func upsertProfile(_ profile: ProviderProfile, in config: inout ProviderConfigFile) throws {
        try profile.validate()
        if let index = config.profiles.firstIndex(where: { $0.id == profile.id }) {
            config.profiles[index] = profile
        } else {
            config.profiles.append(profile)
        }
        if config.defaultProfileID == nil {
            config.defaultProfileID = profile.id
        }
        try save(config)
    }

    public func deleteProfile(id: String, from config: inout ProviderConfigFile) throws {
        config.profiles.removeAll { $0.id == id }
        if config.defaultProfileID == id {
            config.defaultProfileID = config.profiles.first?.id
        }
        try credentialResolver.store.delete(account: ProviderCredentialResolver.keychainAccount(for: id))
        try save(config)
    }

    public static func bootstrapDefaultConfig() -> ProviderConfigFile {
        let profile = ProviderProfile.makeDefault(from: ProviderPresetCatalog.anthropic, name: "Anthropic")
        return ProviderConfigFile(
            version: ProviderConfigFile.currentVersion,
            defaultProfileID: profile.id,
            profiles: [profile]
        )
    }
}
