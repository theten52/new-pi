import Foundation

/// UserDefaults-first credential store with optional Keychain mirror (AIChatMac-style).
public struct LayeredCredentialStore: CredentialStore, @unchecked Sendable {
    public var userDefaultsStore: UserDefaultsCredentialStore
    public var keychainStore: KeychainCredentialStore
    public var useKeychain: @Sendable () -> Bool

    public init(
        userDefaultsStore: UserDefaultsCredentialStore = UserDefaultsCredentialStore(),
        keychainStore: KeychainCredentialStore = KeychainCredentialStore(),
        useKeychain: @escaping @Sendable () -> Bool = { ProviderCredentialPreferences.load().useKeychain }
    ) {
        self.userDefaultsStore = userDefaultsStore
        self.keychainStore = keychainStore
        self.useKeychain = useKeychain
    }

    public func load(account: String) throws -> String? {
        if let userDefaultsValue = try userDefaultsStore.load(account: account)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !userDefaultsValue.isEmpty {
            return userDefaultsValue
        }

        guard useKeychain() else { return nil }

        return try keychainStore.load(account: account)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public func save(account: String, secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: account)
            return
        }

        try userDefaultsStore.save(account: account, secret: trimmed)
        if useKeychain() {
            try keychainStore.save(account: account, secret: trimmed)
        }
    }

    public func delete(account: String) throws {
        try userDefaultsStore.delete(account: account)
        guard useKeychain() else { return }
        try keychainStore.delete(account: account)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
