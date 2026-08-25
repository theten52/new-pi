import Foundation

public enum MCPProtocol {
    public static let protocolVersion = "2024-11-05"
    public static let clientName = "NewPi"
    public static let clientVersion = "0.1"
    public static let defaultCallTimeoutSeconds: TimeInterval = 30
}

public struct MCPToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue

    public init(name: String, description: String?, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum MCPProtocolError: LocalizedError, Sendable, Equatable {
    case handshakeFailed(String)
    case rpcError(code: Int, message: String)
    case invalidResponse(String)
    case toolCallFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .handshakeFailed(message):
            message
        case let .rpcError(_, message):
            message
        case let .invalidResponse(message):
            message
        case let .toolCallFailed(message):
            message
        }
    }
}

public enum MCPToolName: Sendable {
    public static let prefix = "mcp/"

    public static func qualified(serverId: String, toolName: String) -> String {
        "\(prefix)\(serverId)/\(toolName)"
    }

    public static func parse(_ qualifiedName: String) -> (serverId: String, toolName: String)? {
        guard qualifiedName.hasPrefix(prefix) else { return nil }
        let remainder = String(qualifiedName.dropFirst(prefix.count))
        guard let slashIndex = remainder.firstIndex(of: "/") else { return nil }
        let serverId = String(remainder[..<slashIndex])
        let toolName = String(remainder[remainder.index(after: slashIndex)...])
        guard !serverId.isEmpty, !toolName.isEmpty else { return nil }
        return (serverId, toolName)
    }
}

public enum MCPSchemaMapper {
    public static func toolDefinition(serverId: String, tool: MCPToolDefinition) -> ToolDefinition? {
        guard !tool.name.isEmpty else { return nil }
        return ToolDefinition(
            name: MCPToolName.qualified(serverId: serverId, toolName: tool.name),
            description: tool.description ?? "MCP tool \(tool.name)",
            parameters: tool.inputSchema
        )
    }

    public static func parseToolsList(_ result: JSONValue?) -> [MCPToolDefinition] {
        guard case let .object(root) = result,
              case let .array(tools) = root["tools"] else {
            return []
        }
        return tools.compactMap(parseToolEntry)
    }

    private static func parseToolEntry(_ value: JSONValue) -> MCPToolDefinition? {
        guard case let .object(object) = value,
              case let .string(name) = object["name"],
              !name.isEmpty else {
            return nil
        }

        let description: String?
        if case let .string(text) = object["description"] {
            description = text
        } else {
            description = nil
        }

        let schema: JSONValue
        if case let .object(inputSchema) = object["inputSchema"] {
            schema = .object(inputSchema)
        } else {
            schema = defaultObjectSchema()
        }

        return MCPToolDefinition(name: name, description: description, inputSchema: schema)
    }

    public static func defaultObjectSchema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    }

    public static func toolCallResultText(_ result: JSONValue?) -> String {
        guard case let .object(root) = result else { return "" }

        if case let .array(content) = root["content"] {
            let parts = content.compactMap { item -> String? in
                guard case let .object(object) = item,
                      case let .string(text) = object["text"] else {
                    return nil
                }
                return text
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }

        if let result, let data = try? result.toJSONData(),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return ""
    }
}
