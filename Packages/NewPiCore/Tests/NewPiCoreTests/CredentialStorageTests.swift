import Foundation
import Testing
@testable import NewPiCore

@Suite("LayeredCredentialStore")
struct LayeredCredentialStoreTests {
    @Test("prefers UserDefaults when Keychain is disabled")
    func userDefaultsFirst() throws {
        let userDefaults = UserDefaultsCredentialStore(defaults: makeIsolatedDefaults())
        let keychain = KeychainCredentialStore(service: "com.new-pi.test.\(UUID().uuidString)")
        let store = LayeredCredentialStore(
            userDefaultsStore: userDefaults,
            keychainStore: keychain,
            useKeychain: { false }
        )

        try keychain.save(account: "provider:test:apiKey", secret: "from-keychain")
        try userDefaults.save(account: "provider:test:apiKey", secret: "from-defaults")

        let loaded = try store.load(account: "provider:test:apiKey")
        #expect(loaded == "from-defaults")
    }

    @Test("falls back to Keychain only when enabled")
    func keychainFallback() throws {
        let userDefaults = UserDefaultsCredentialStore(defaults: makeIsolatedDefaults())
        let keychain = KeychainCredentialStore(service: "com.new-pi.test.\(UUID().uuidString)")
        let store = LayeredCredentialStore(
            userDefaultsStore: userDefaults,
            keychainStore: keychain,
            useKeychain: { true }
        )

        try keychain.save(account: "provider:test:apiKey", secret: "from-keychain")

        let loaded = try store.load(account: "provider:test:apiKey")
        #expect(loaded == "from-keychain")
    }

    @Test("save writes UserDefaults always and Keychain when enabled")
    func saveBehavior() throws {
        let userDefaults = UserDefaultsCredentialStore(defaults: makeIsolatedDefaults())
        let keychain = KeychainCredentialStore(service: "com.new-pi.test.\(UUID().uuidString)")
        let store = LayeredCredentialStore(
            userDefaultsStore: userDefaults,
            keychainStore: keychain,
            useKeychain: { true }
        )

        try store.save(account: "provider:test:apiKey", secret: "secret")

        #expect(try userDefaults.load(account: "provider:test:apiKey") == "secret")
        #expect(try keychain.load(account: "provider:test:apiKey") == "secret")
    }

    @Test("skips Keychain migration after first attempt")
    func migrationRunsOnce() throws {
        let migrationKey = ProviderCredentialPreferences.keychainMigrationAttemptedKey
        let hadPriorAttempt = UserDefaults.standard.bool(forKey: migrationKey)
        defer { UserDefaults.standard.set(hadPriorAttempt, forKey: migrationKey) }
        UserDefaults.standard.set(true, forKey: migrationKey)

        let keychain = KeychainCredentialStore(service: "com.new-pi.test.\(UUID().uuidString)")
        try keychain.save(account: "provider:test:apiKey", secret: "secret")

        let userDefaults = UserDefaultsCredentialStore(defaults: makeIsolatedDefaults())
        let resolver = ProviderCredentialResolver(
            store: LayeredCredentialStore(
                userDefaultsStore: userDefaults,
                keychainStore: keychain,
                useKeychain: { false }
            ),
            environment: { [:] }
        )

        let profile = ProviderProfile(
            id: "test",
            name: "Test",
            preset: .anthropic,
            modelID: "claude-sonnet-4-20250514"
        )
        try resolver.migrateKeychainSecretsToUserDefaultsIfNeeded(profiles: [profile])

        #expect(try userDefaults.load(account: "provider:test:apiKey") == nil)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.new-pi.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@Suite("ProviderCredentialPreferences")
struct ProviderCredentialPreferencesTests {
    @Test("defaults useKeychain to false")
    func defaultOff() {
        let defaults = UserDefaults(suiteName: "com.new-pi.prefs.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.description)
        let prefs = ProviderCredentialPreferences.load(defaults: defaults, processEnvironment: [:])
        #expect(prefs.useKeychain == false)
    }
}

@Suite("DevelopmentEnvFile")
struct DevelopmentEnvFileTests {
    @Test("parses dotenv values")
    func parseDotEnv() {
        let values = DotEnvFile.parse("""
        ANTHROPIC_API_KEY=sk-test
        # comment
        OPENAI_API_KEY="quoted"
        """)
        #expect(values["ANTHROPIC_API_KEY"] == "sk-test")
        #expect(values["OPENAI_API_KEY"] == "quoted")
    }
}
