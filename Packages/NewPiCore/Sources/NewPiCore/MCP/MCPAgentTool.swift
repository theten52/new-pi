import Foundation

public struct MCPAgentTool: AgentTool {
    public let serverId: String
    public let mcpToolName: String
    public let toolDescription: String?
    public let inputSchema: JSONValue

    public var name: String {
        MCPToolName.qualified(serverId: serverId, toolName: mcpToolName)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: toolDescription ?? "MCP tool \(mcpToolName)",
            parameters: inputSchema
        )
    }

    public init(serverId: String, definition: MCPToolDefinition) {
        self.serverId = serverId
        mcpToolName = definition.name
        toolDescription = definition.description
        inputSchema = definition.inputSchema
    }

    public func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        onUpdate?(ToolProgress(message: "Calling MCP tool \(mcpToolName)…"))
        do {
            let content = try await MCPPluginManager.shared.callTool(
                serverId: serverId,
                toolName: mcpToolName,
                arguments: arguments
            )
            return ToolResult(content: content)
        } catch {
            return ToolResult(content: error.localizedDescription, isError: true)
        }
    }
}

public enum MCPToolLoader {
    public static func loadAgentTools() async -> [MCPAgentTool] {
        guard MCPPreferences.allowMCPToolsInChat else { return [] }

        let grouped = await MCPPluginManager.shared.allToolDefinitions()
        var tools: [MCPAgentTool] = []
        for (serverId, definitions) in grouped {
            for definition in definitions {
                if MCPSchemaMapper.toolDefinition(serverId: serverId, tool: definition) != nil {
                    tools.append(MCPAgentTool(serverId: serverId, definition: definition))
                } else {
                    NewPiLogger.error(
                        category: "mcp",
                        message: "Skipped invalid MCP tool schema",
                        details: "server=\(serverId) tool=\(definition.name)"
                    )
                }
            }
        }
        NewPiLogger.info(
            category: "mcp",
            message: "Loaded MCP tools",
            details: "count=\(tools.count)"
        )
        return tools
    }
}
