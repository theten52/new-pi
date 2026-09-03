import Foundation

public struct ProviderCredentialResolver: Sendable {
    public var store: any CredentialStore
    public var environment: @Sendable () -> [String: String]

    public init(
        store: any CredentialStore = ProviderCredentialResolver.makeDefaultStore(),
        environment: @escaping @Sendable () -> [String: String] = ProviderCredentialResolver.makeDefaultEnvironment
    ) {
        self.store = store
        self.environment = environment
    }

    public static func makeDefaultStore() -> any CredentialStore {
        LayeredCredentialStore()
    }

    public static func makeDefaultEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let devEnv = DevelopmentEnvFile.loadEnvironment()
        for (key, value) in devEnv where env[key]?.isEmpty != false {
            env[key] = value
        }
        return env
    }

    public static func makeDefault() -> ProviderCredentialResolver {
        ProviderCredentialResolver(
            store: makeDefaultStore(),
            environment: makeDefaultEnvironment
        )
    }

    public static func keychainAccount(for profileID: String) -> String {
        "provider:\(profileID):apiKey"
    }

    public static let legacyAnthropicAccount = "anthropic-api-key"

    public func apiKey(for profile: ProviderProfile) async throws -> String {
        guard profile.preset.credentialRequired else {
            return ""
        }

        let env = environment()
        if let envKey = profile.preset.environmentVariable,
           let value = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        let account = Self.keychainAccount(for: profile.id)
        if let stored = try store.load(account: account)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }

        throw AgentError.llmFailed(
            "Missing API key for \"\(profile.name)\". Set \(profile.preset.environmentVariable ?? "an API key") or save it in NewPi Settings."
        )
    }

    public func saveAPIKey(_ secret: String, for profile: ProviderProfile) async throws {
        let account = Self.keychainAccount(for: profile.id)
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try store.delete(account: account)
            return
        }
        try store.save(account: account, secret: trimmed)
    }

    public func hasAPIKey(for profile: ProviderProfile) async -> Bool {
        guard profile.preset.credentialRequired else { return true }
        return (try? await apiKey(for: profile)) != nil
    }

    /// One-time copy from Keychain → UserDefaults when Keychain storage is disabled.
    public func migrateKeychainSecretsToUserDefaultsIfNeeded(profiles: [ProviderProfile]) throws {
        guard !ProviderCredentialPreferences.load().useKeychain else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: ProviderCredentialPreferences.keychainMigrationAttemptedKey) else {
            return
        }
        defer {
            defaults.set(true, forKey: ProviderCredentialPreferences.keychainMigrationAttemptedKey)
        }

        let layeredStore = store as? LayeredCredentialStore
        let userDefaultsStore = layeredStore?.userDefaultsStore ?? UserDefaultsCredentialStore()
        let keychainStore = layeredStore?.keychainStore ?? KeychainCredentialStore()

        var accounts = Set(profiles.map { Self.keychainAccount(for: $0.id) })
        accounts.insert(Self.legacyAnthropicAccount)

        for account in accounts {
            if let existing = try userDefaultsStore.load(account: account)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty {
                continue
            }
            guard let keychainValue = try keychainStore.load(account: account)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !keychainValue.isEmpty else {
                continue
            }
            try userDefaultsStore.save(account: account, secret: keychainValue)
        }
    }

    /// Migrates legacy `anthropic-api-key` to the default profile account.
    /// Operates on the unified `store` abstraction, so it works for any
    /// `CredentialStore` (Keychain, Layered, or in-memory test stores). The
    /// store itself decides which backing layer(s) to read from and write to.
    public func migrateLegacyAnthropicKeyIfNeeded() throws {
        let legacyAccount = Self.legacyAnthropicAccount
        let newAccount = Self.keychainAccount(for: ProviderConfigFile.defaultAnthropicProfileID)
        guard try store.load(account: newAccount) == nil,
              let legacy = try store.load(account: legacyAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty
        else {
            return
        }
        try store.save(account: newAccount, secret: legacy)
    }
}
