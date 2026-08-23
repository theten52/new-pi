import Foundation

public struct ProviderCredentialResolver: Sendable {
    public var store: any CredentialStore
    public var environment: @Sendable () -> [String: String]

    public init(
        store: any CredentialStore = KeychainCredentialStore(),
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.store = store
        self.environment = environment
    }

    public static func keychainAccount(for profileID: String) -> String {
        "provider:\(profileID):apiKey"
    }

    public static let legacyAnthropicAccount = "anthropic-api-key"

    public func apiKey(for profile: ProviderProfile) async throws -> String {
        let definition = ProviderPresetCatalog.definition(for: profile.preset)
        guard definition.credentialRequired else {
            return ""
        }

        let env = environment()
        if let envKey = definition.environmentVariable,
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
            "Missing API key for \"\(profile.name)\". Set \(definition.environmentVariable ?? "an API key") or save it in NewPi Settings."
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
        let definition = ProviderPresetCatalog.definition(for: profile.preset)
        guard definition.credentialRequired else { return true }
        return (try? await apiKey(for: profile)) != nil
    }

    /// Migrates legacy `anthropic-api-key` to the default profile keychain account.
    public func migrateLegacyAnthropicKeyIfNeeded() throws {
        let legacyAccount = Self.legacyAnthropicAccount
        let newAccount = Self.keychainAccount(for: ProviderConfigFile.defaultAnthropicProfileID)
        guard try store.load(account: newAccount) == nil,
              let legacy = try store.load(account: legacyAccount),
              !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        try store.save(account: newAccount, secret: legacy)
    }
}
