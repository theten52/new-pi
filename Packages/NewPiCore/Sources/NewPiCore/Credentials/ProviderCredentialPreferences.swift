import Foundation

public struct ProviderCredentialPreferences: Sendable, Equatable {
    public static let useKeychainDefaultsKey = "newPiUseKeychain"
    public static let useKeychainEnvironmentVariable = "NEW_PI_USE_KEYCHAIN"
    /// When Keychain is off, migration from Keychain → UserDefaults runs at most once.
    public static let keychainMigrationAttemptedKey = "newPiKeychainMigrationAttempted"

    public var useKeychain: Bool

    public init(useKeychain: Bool) {
        self.useKeychain = useKeychain
    }

    public static func load(
        defaults: UserDefaults = .standard,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderCredentialPreferences {
        if defaults.object(forKey: useKeychainDefaultsKey) != nil {
            return ProviderCredentialPreferences(useKeychain: defaults.bool(forKey: useKeychainDefaultsKey))
        }

        if let envValue = processEnvironment[useKeychainEnvironmentVariable] {
            return ProviderCredentialPreferences(useKeychain: parseBoolean(envValue))
        }

        // Default off: avoids Keychain password prompts on every Xcode debug rebuild.
        return ProviderCredentialPreferences(useKeychain: false)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(useKeychain, forKey: Self.useKeychainDefaultsKey)
    }

    private static func parseBoolean(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        default:
            false
        }
    }
}
