import Foundation

public enum MCPServerConnectionState: String, Sendable, Equatable {
    case stopped = "Stopped"
    case starting = "Starting"
    case ready = "Ready"
    case failed = "Failed"
}

public struct MCPServerStatus: Sendable, Equatable, Identifiable {
    public let id: String
    public var source: MCPConfigSource
    public var state: MCPServerConnectionState
    public var toolCount: Int
    public var lastError: String?
    public var isEnabled: Bool
    public var isInCooldown: Bool

    public init(
        id: String,
        source: MCPConfigSource,
        state: MCPServerConnectionState,
        toolCount: Int,
        lastError: String?,
        isEnabled: Bool,
        isInCooldown: Bool
    ) {
        self.id = id
        self.source = source
        self.state = state
        self.toolCount = toolCount
        self.lastError = lastError
        self.isEnabled = isEnabled
        self.isInCooldown = isInCooldown
    }
}

public actor MCPPluginManager {
    public static let shared = MCPPluginManager()

    private var config: MCPLoadedConfig
    private let transportFactory: @Sendable (String) -> MCPTransporting
    private var connections: [String: MCPConnection] = [:]
    private var cachedToolCounts: [String: Int] = [:]
    private var failureCounts: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private var lastFailureMessages: [String: String] = [:]
    private let maxFailuresBeforeCooldown = 3
    private let cooldownInterval: TimeInterval = 60

    public init(
        config: MCPLoadedConfig = MCPConfigStore.load(),
        transportFactory: (@Sendable (String) -> MCPTransporting)? = nil
    ) {
        self.config = config
        self.transportFactory = transportFactory ?? { _ in MCPStdioTransport() }
    }

    public func reloadConfiguration() {
        config = MCPConfigStore.load()
    }

    public func currentConfig() -> MCPLoadedConfig {
        config
    }

    public func serverStatuses() -> [MCPServerStatus] {
        config.servers.keys.sorted().map { serverId in
            let definition = config.servers[serverId]!
            let enabled = MCPPreferences.isServerEnabled(serverId: serverId, configDisabled: definition.disabled)
            let state: MCPServerConnectionState
            if connections[serverId] != nil {
                state = .ready
            } else if enabled, isInCooldown(serverId: serverId) {
                state = .failed
            } else {
                state = .stopped
            }

            return MCPServerStatus(
                id: serverId,
                source: definition.source,
                state: state,
                toolCount: cachedToolCounts[serverId] ?? 0,
                lastError: lastFailureMessages[serverId],
                isEnabled: enabled,
                isInCooldown: isInCooldown(serverId: serverId)
            )
        }
    }

    public func setServerEnabled(_ enabled: Bool, serverId: String) async {
        MCPPreferences.setServerEnabled(enabled, serverId: serverId)
        if !enabled {
            await stopServer(serverId: serverId)
        }
    }

    public func restartServer(serverId: String) async {
        await stopServer(serverId: serverId)
        failureCounts[serverId] = 0
        cooldownUntil[serverId] = nil
        _ = try? await connection(for: serverId)
    }

    func connection(for serverId: String) async throws -> MCPConnection {
        if let existing = connections[serverId] {
            return existing
        }

        guard MCPPreferences.allowMCPToolsInChat else {
            throw MCPProtocolError.toolCallFailed("MCP tools are disabled")
        }

        guard let definition = config.servers[serverId] else {
            throw MCPProtocolError.toolCallFailed("Unknown MCP server")
        }

        guard MCPPreferences.isServerEnabled(serverId: serverId, configDisabled: definition.disabled) else {
            throw MCPProtocolError.toolCallFailed("MCP server is disabled")
        }

        if isInCooldown(serverId: serverId) {
            throw MCPProtocolError.toolCallFailed("MCP server is cooling down after repeated failures")
        }

        let transport = transportFactory(serverId)
        let connection = MCPConnection(serverId: serverId, transport: transport)

        do {
            let resolvedEnvironment = try MCPConfigStore.resolvedEnvironment(for: definition)
            try await connection.connect(definition: definition, resolvedEnvironment: resolvedEnvironment)
            connections[serverId] = connection
            failureCounts[serverId] = 0
            cooldownUntil[serverId] = nil
            let toolCount = await connection.tools.count
            cachedToolCounts[serverId] = toolCount
            NewPiLogger.info(
                category: "mcp",
                message: "MCP server ready",
                details: "server=\(serverId) tools=\(toolCount)"
            )
            return connection
        } catch {
            recordFailure(serverId: serverId, error: error)
            await connection.shutdown()
            NewPiLogger.error(
                category: "mcp",
                message: "MCP server failed",
                details: "server=\(serverId) \(sanitized(error))"
            )
            throw error
        }
    }

    public func allToolDefinitions() async -> [(serverId: String, tools: [MCPToolDefinition])] {
        guard MCPPreferences.allowMCPToolsInChat else { return [] }

        var results: [(String, [MCPToolDefinition])] = []
        for serverId in config.servers.keys.sorted() {
            let definition = config.servers[serverId]!
            guard MCPPreferences.isServerEnabled(serverId: serverId, configDisabled: definition.disabled) else {
                continue
            }
            do {
                let connection = try await connection(for: serverId)
                let tools = await connection.tools
                results.append((serverId, tools))
                cachedToolCounts[serverId] = tools.count
            } catch {
                continue
            }
        }
        return results
    }

    public func callTool(serverId: String, toolName: String, arguments: JSONValue) async throws -> String {
        let connection = try await connection(for: serverId)
        return try await connection.callTool(name: toolName, arguments: arguments)
    }

    public func shutdownAll() async {
        for (serverId, connection) in connections {
            await connection.shutdown()
            connections[serverId] = nil
        }
        connections.removeAll()
    }

    public func stopServer(serverId: String) async {
        if let connection = connections.removeValue(forKey: serverId) {
            await connection.shutdown()
        }
    }

    private func recordFailure(serverId: String, error: Error) {
        let count = (failureCounts[serverId] ?? 0) + 1
        failureCounts[serverId] = count
        if count >= maxFailuresBeforeCooldown {
            cooldownUntil[serverId] = Date().addingTimeInterval(cooldownInterval)
        }
        lastFailureMessages[serverId] = sanitized(error)
    }

    private func isInCooldown(serverId: String) -> Bool {
        guard let until = cooldownUntil[serverId] else { return false }
        if until <= Date() {
            cooldownUntil[serverId] = nil
            return false
        }
        return true
    }

    private func sanitized(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "MCP server failed"
    }
}
