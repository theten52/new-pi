import Foundation

/// Stores secrets in UserDefaults — stable across Xcode debug rebuilds (no Keychain password prompts).
public final class UserDefaultsCredentialStore: CredentialStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "com.new-pi.credential.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func storageKey(for account: String) -> String {
        keyPrefix + account
    }

    public func load(account: String) throws -> String? {
        defaults.string(forKey: storageKey(for: account))
    }

    public func save(account: String, secret: String) throws {
        defaults.set(secret, forKey: storageKey(for: account))
    }

    public func delete(account: String) throws {
        defaults.removeObject(forKey: storageKey(for: account))
    }
}
