import Foundation

public enum MCPConfigSource: String, Sendable, Codable, Equatable {
    case agentDirectory
}

public struct MCPServerDefinition: Sendable, Equatable, Codable {
    public let command: String
    public let args: [String]
    public let env: [String: String]
    public let disabled: Bool
    public let source: MCPConfigSource

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        disabled: Bool = false,
        source: MCPConfigSource = .agentDirectory
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.disabled = disabled
        self.source = source
    }
}

public struct MCPLoadedConfig: Sendable, Equatable {
    public let servers: [String: MCPServerDefinition]
    public let configPath: URL

    public init(servers: [String: MCPServerDefinition], configPath: URL) {
        self.servers = servers
        self.configPath = configPath
    }
}

public enum MCPConfigError: LocalizedError, Sendable, Equatable {
    case invalidJSON(String)
    case missingCommand(serverId: String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidJSON(path):
            "Invalid MCP configuration at \(path)"
        case let .missingCommand(serverId):
            "MCP server \"\(serverId)\" is missing a command"
        case let .readFailed(path):
            "Unable to read MCP configuration at \(path)"
        }
    }
}

private struct MCPConfigFileDTO: Decodable {
    let mcpServers: [String: MCPServerEntryDTO]?

    enum CodingKeys: String, CodingKey {
        case mcpServers
    }
}

private struct MCPServerEntryDTO: Decodable {
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let disabled: Bool?
}

public enum MCPConfigPaths {
    public static let configFileName = "mcp.json"

    public static func configURL(agentDirectory: URL = NewPiConfig.defaultAgentDirectory) -> URL {
        agentDirectory.appendingPathComponent(configFileName, isDirectory: false)
    }

    public static func ensureConfigDirectory(
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory,
        fileManager: FileManager = .default
    ) throws {
        if !fileManager.fileExists(atPath: agentDirectory.path) {
            try fileManager.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        }
    }
}

public enum MCPPreferences {
    public static let allowMCPToolsInChatKey = "newPi.allowMCPToolsInChat"
    public static let mcpConsentAcknowledgedKey = "newPi.mcpConsentAcknowledged"
    public static let serverEnabledPrefix = "newPi.mcpServerEnabled."

    public static var allowMCPToolsInChat: Bool {
        get {
            if ProcessInfo.processInfo.environment["NEW_PI_MCP"] == "1" {
                return true
            }
            return UserDefaults.standard.bool(forKey: allowMCPToolsInChatKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: allowMCPToolsInChatKey)
        }
    }

    public static var mcpConsentAcknowledged: Bool {
        get { UserDefaults.standard.bool(forKey: mcpConsentAcknowledgedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mcpConsentAcknowledgedKey) }
    }

    public static func isServerEnabled(serverId: String, configDisabled: Bool) -> Bool {
        if configDisabled { return false }
        let key = serverEnabledPrefix + serverId
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    public static func setServerEnabled(_ enabled: Bool, serverId: String) {
        UserDefaults.standard.set(enabled, forKey: serverEnabledPrefix + serverId)
    }
}

public enum MCPConfigParser {
    public static func parseFile(
        at url: URL,
        source: MCPConfigSource = .agentDirectory
    ) throws -> [String: MCPServerDefinition] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MCPConfigError.readFailed(url.path)
        }

        let dto: MCPConfigFileDTO
        do {
            dto = try JSONDecoder().decode(MCPConfigFileDTO.self, from: data)
        } catch {
            throw MCPConfigError.invalidJSON(url.path)
        }

        guard let entries = dto.mcpServers else {
            return [:]
        }

        var servers: [String: MCPServerDefinition] = [:]
        for (serverId, entry) in entries {
            guard let command = entry.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                throw MCPConfigError.missingCommand(serverId: serverId)
            }
            servers[serverId] = MCPServerDefinition(
                command: command,
                args: entry.args ?? [],
                env: entry.env ?? [:],
                disabled: entry.disabled ?? false,
                source: source
            )
        }
        return servers
    }
}

public enum MCPConfigStore {
    public static func load(agentDirectory: URL = NewPiConfig.defaultAgentDirectory) -> MCPLoadedConfig {
        let configURL = MCPConfigPaths.configURL(agentDirectory: agentDirectory)
        try? MCPConfigPaths.ensureConfigDirectory(agentDirectory: agentDirectory)
        let servers = (try? MCPConfigParser.parseFile(at: configURL)) ?? [:]
        return MCPLoadedConfig(servers: servers, configPath: configURL)
    }

    public static func resolvedEnvironment(for definition: MCPServerDefinition) throws -> [String: String] {
        try MCPSecretsResolver().resolve(definition.env)
    }
}
