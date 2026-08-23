import Foundation
import Security

public enum CredentialProvider: String, Sendable, Codable, CaseIterable {
    case anthropic
    case openai

    public var keychainAccount: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .openai: "openai-api-key"
        }
    }

    public var environmentVariable: String {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
        }
    }
}

public protocol CredentialStore: Sendable {
    func load(account: String) throws -> String?
    func save(account: String, secret: String) throws
    func delete(account: String) throws
}

public enum CredentialStoreError: Error, Sendable, Equatable {
    case unhandledStatus(OSStatus)
    case invalidData
}

extension CredentialStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unhandledStatus(status):
            "Keychain operation failed with status \(status)"
        case .invalidData:
            "Keychain returned invalid credential data"
        }
    }
}

/// SECURITY-REVIEW: Stores provider API keys in the macOS Keychain.
public struct KeychainCredentialStore: CredentialStore, Sendable {
    public var service: String

    public init(service: String = "com.new-pi.credentials") {
        self.service = service
    }

    public func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unhandledStatus(status)
        }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidData
        }
        return secret
    }

    public func save(account: String, secret: String) throws {
        let encoded = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var createQuery = query
            createQuery[kSecValueData as String] = encoded
            let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.unhandledStatus(addStatus)
            }
            return
        }
        throw CredentialStoreError.unhandledStatus(updateStatus)
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unhandledStatus(status)
        }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    public init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func load(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    public func save(account: String, secret: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    public func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}

public struct CredentialResolver: Sendable {
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

    public func apiKey(for provider: CredentialProvider) async throws -> String {
        let env = environment()
        if let value = env[provider.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        if let stored = try store.load(account: provider.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }

        throw AgentError.llmFailed(
            "Missing API key for \(provider.rawValue). Set \(provider.environmentVariable) or save it in NewPi Settings."
        )
    }

    public func saveAPIKey(_ secret: String, for provider: CredentialProvider) async throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try store.delete(account: provider.keychainAccount)
            return
        }
        try store.save(account: provider.keychainAccount, secret: trimmed)
    }

    public func hasAPIKey(for provider: CredentialProvider) async throws -> Bool {
        do {
            _ = try await apiKey(for: provider)
            return true
        } catch {
            return false
        }
    }
}
