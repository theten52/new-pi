import Foundation
import Security

public protocol MCPSecretsResolving: Sendable {
    func resolve(_ values: [String: String]) throws -> [String: String]
}

public enum MCPSecretsError: LocalizedError, Sendable, Equatable {
    case missingEnvironmentVariable(String)
    case missingKeychainValue(String)
    case keychainReadFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingEnvironmentVariable(name):
            "Missing environment variable for MCP: \(name)"
        case let .missingKeychainValue(account):
            "Missing Keychain value for MCP: \(account)"
        case .keychainReadFailed:
            "Unable to read MCP secret from Keychain"
        }
    }
}

public struct MCPSecretsResolver: MCPSecretsResolving {
    private let environment: [String: String]
    private let keychainService: String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "com.newpi.mcp"
    ) {
        self.environment = environment
        self.keychainService = keychainService
    }

    public func resolve(_ values: [String: String]) throws -> [String: String] {
        var resolved: [String: String] = [:]
        for (key, rawValue) in values {
            resolved[key] = try resolveValue(rawValue)
        }
        return resolved
    }

    private func resolveValue(_ rawValue: String) throws -> String {
        if rawValue.hasPrefix("${"), rawValue.hasSuffix("}") {
            let variableName = String(rawValue.dropFirst(2).dropLast())
            guard !variableName.isEmpty else { return rawValue }
            guard let value = environment[variableName], !value.isEmpty else {
                throw MCPSecretsError.missingEnvironmentVariable(variableName)
            }
            return value
        }

        if rawValue.hasPrefix("env:") {
            let account = String(rawValue.dropFirst("env:".count))
            guard !account.isEmpty else { return rawValue }
            guard let value = try loadKeychain(account: account), !value.isEmpty else {
                throw MCPSecretsError.missingKeychainValue(account)
            }
            return value
        }

        return rawValue
    }

    private func loadKeychain(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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
            throw MCPSecretsError.keychainReadFailed("status \(status)")
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
