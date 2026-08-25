import Foundation

actor MCPConnection {
    private let serverId: String
    private let transport: MCPTransporting
    private let callTimeout: TimeInterval
    private var nextRequestID = 1
    private(set) var tools: [MCPToolDefinition] = []
    private var isInitialized = false

    init(
        serverId: String,
        transport: MCPTransporting,
        callTimeout: TimeInterval = MCPProtocol.defaultCallTimeoutSeconds
    ) {
        self.serverId = serverId
        self.transport = transport
        self.callTimeout = callTimeout
    }

    func connect(definition: MCPServerDefinition, resolvedEnvironment: [String: String]) async throws {
        try await transport.start(
            command: definition.command,
            arguments: definition.args,
            environment: resolvedEnvironment
        )

        let initializeParams: JSONValue = .object([
            "protocolVersion": .string(MCPProtocol.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(MCPProtocol.clientName),
                "version": .string(MCPProtocol.clientVersion),
            ]),
        ])
        _ = try await sendRequest(method: "initialize", params: initializeParams)

        let initialized = JSONRPCNotification(method: "notifications/initialized")
        try await transport.send(frame: try MCPJSONRPC.encodeNotification(initialized))

        let toolsResponse = try await sendRequest(method: "tools/list", params: nil)
        tools = MCPSchemaMapper.parseToolsList(toolsResponse.result)
        isInitialized = true
    }

    func callTool(name: String, arguments: JSONValue) async throws -> String {
        guard isInitialized else {
            throw MCPProtocolError.toolCallFailed("MCP server is not ready")
        }

        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
        ])
        let response = try await sendRequest(method: "tools/call", params: params)
        if let error = response.error {
            throw MCPProtocolError.rpcError(code: error.code, message: error.message)
        }
        return MCPSchemaMapper.toolCallResultText(response.result)
    }

    func shutdown() async {
        await transport.close()
        isInitialized = false
        tools = []
    }

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        let request = JSONRPCRequest(id: nextRequestID, method: method, params: params)
        nextRequestID += 1
        try await transport.send(frame: try MCPJSONRPC.encodeRequest(request))

        let responseData = try await transport.receiveResponse(timeout: callTimeout)
        let response = try MCPJSONRPC.decodeResponse(responseData)
        if let error = response.error {
            throw MCPProtocolError.rpcError(code: error.code, message: error.message)
        }
        if response.id != request.id {
            throw MCPProtocolError.invalidResponse("MCP response id mismatch for \(serverId)")
        }
        return response
    }
}
