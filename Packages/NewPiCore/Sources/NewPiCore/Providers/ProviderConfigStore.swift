import Foundation

public struct ProviderConfigStore {
    public var configURL: URL
    public var credentialResolver: ProviderCredentialResolver

    public init(
        configURL: URL = NewPiConfig.defaultAgentDirectory.appendingPathComponent("providers.json"),
        credentialResolver: ProviderCredentialResolver = ProviderCredentialResolver.makeDefault()
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
            try credentialResolver.migrateKeychainSecretsToUserDefaultsIfNeeded(profiles: validated.profiles)
            return validated
        }

        try credentialResolver.migrateLegacyAnthropicKeyIfNeeded()
        let defaultConfig = Self.bootstrapDefaultConfig()
        try credentialResolver.migrateKeychainSecretsToUserDefaultsIfNeeded(profiles: defaultConfig.profiles)
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

    public func upsertProfile(
        _ profile: ProviderProfile,
        in config: inout ProviderConfigFile,
        setAsDefault: Bool = false
    ) throws {
        var mutableProfile = profile
        try mutableProfile.validateAndSync()
        let isNew = !config.profiles.contains(where: { $0.id == mutableProfile.id })
        if let index = config.profiles.firstIndex(where: { $0.id == mutableProfile.id }) {
            config.profiles[index] = mutableProfile
        } else {
            config.profiles.append(mutableProfile)
        }
        if setAsDefault || isNew {
            config.defaultProfileID = mutableProfile.id
        } else if config.defaultProfileID == nil {
            config.defaultProfileID = mutableProfile.id
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
        var profile = VendorPresets.makeProfile(from: VendorPresets.anthropic)
        // 保持既有 keychain 迁移逻辑兼容（legacyAnthropicAccount → 固定 id）。
        profile.id = ProviderConfigFile.defaultAnthropicProfileID
        return ProviderConfigFile(
            version: ProviderConfigFile.currentVersion,
            defaultProfileID: profile.id,
            profiles: [profile]
        )
    }
}
