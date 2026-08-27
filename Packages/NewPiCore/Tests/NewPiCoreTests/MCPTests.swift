import Foundation
import Testing
@testable import NewPiCore

@Suite("MCPJSONRPC")
struct MCPJSONRPCTests {
    @Test("encodeFrame prefixes content length")
    func encodeFrame() {
        let payload = Data("{\"jsonrpc\":\"2.0\"}".utf8)
        let framed = MCPJSONRPC.encodeFrame(payload: payload)
        let text = String(data: framed, encoding: .utf8)
        #expect(text?.hasPrefix("Content-Length: \(payload.count)\r\n\r\n") == true)
        #expect(framed.suffix(payload.count) == payload)
    }

    @Test("decode single frame from buffer")
    func decodeSingleFrame() throws {
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        var buffer = MCPJSONRPC.encodeFrame(payload: payload)
        let frames = try MCPJSONRPC.decodeFrames(from: &buffer)
        #expect(frames.count == 1)
        #expect(frames[0] == payload)
        #expect(buffer.isEmpty)
    }

    @Test("incomplete frame waits for more bytes")
    func incompleteFrame() throws {
        let payload = Data("{\"id\":1}".utf8)
        var buffer = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        #expect(throws: MCPJSONRPCFramingError.incompleteFrame) {
            _ = try MCPJSONRPC.decodeFrames(from: &buffer)
        }
        buffer.append(payload)
        let frames = try MCPJSONRPC.decodeFrames(from: &buffer)
        #expect(frames == [payload])
    }
}

@Suite("MCPToolName")
struct MCPToolNameTests {
    @Test("round-trips qualified names")
    func roundTrip() {
        let qualified = MCPToolName.qualified(serverId: "filesystem", toolName: "read")
        #expect(qualified == "mcp/filesystem/read")
        #expect(MCPToolName.parse(qualified)?.serverId == "filesystem")
        #expect(MCPToolName.parse(qualified)?.toolName == "read")
    }
}

@Suite("MCPConnection")
struct MCPConnectionTests {
    @Test("handshake and tool call with mock transport")
    func mockTransport() async throws {
        let initializeResult = try JSONEncoder().encode(
            JSONRPCResponse(
                id: 1,
                result: .object(["protocolVersion": .string(MCPProtocol.protocolVersion)]),
                error: nil
            )
        )
        let toolsListResult = try JSONEncoder().encode(
            JSONRPCResponse(
                id: 2,
                result: .object([
                    "tools": .array([
                        .object([
                            "name": .string("echo"),
                            "description": .string("Echo input"),
                            "inputSchema": MCPSchemaMapper.defaultObjectSchema(),
                        ]),
                    ]),
                ]),
                error: nil
            )
        )
        let toolCallResult = try JSONEncoder().encode(
            JSONRPCResponse(
                id: 3,
                result: .object([
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("hello"),
                        ]),
                    ]),
                ]),
                error: nil
            )
        )

        let transport = MockMCPTransport(responses: [initializeResult, toolsListResult, toolCallResult])
        let connection = MCPConnection(serverId: "mock", transport: transport)
        let definition = MCPServerDefinition(command: "/bin/echo")

        try await connection.connect(definition: definition, resolvedEnvironment: [:])
        let tools = await connection.tools
        #expect(tools.count == 1)
        #expect(tools[0].name == "echo")

        let output = try await connection.callTool(
            name: "echo",
            arguments: .object(["message": .string("hello")])
        )
        #expect(output == "hello")
    }
}

@Suite("MCPConfigParser")
struct MCPConfigParserTests {
    @Test("parses mcp.json entries")
    func parseConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("mcp.json")
        let json = """
        {
          "mcpServers": {
            "demo": {
              "command": "echo",
              "args": ["hello"]
            }
          }
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let servers = try MCPConfigParser.parseFile(at: configURL)
        #expect(servers.count == 1)
        #expect(servers["demo"]?.command == "echo")
        #expect(servers["demo"]?.args == ["hello"])
    }
}

@Suite("MCPStdioTransport")
struct MCPStdioTransportTests {
    @Test("real process round-trip via cat echo")
    func catEchoRoundTrip() async throws {
        let transport = MCPStdioTransport()
        try await transport.start(command: "/bin/cat", arguments: [], environment: [:])

        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        try await transport.send(frame: MCPJSONRPC.encodeFrame(payload: payload))

        // 回归：读循环曾在 actor 上同步阻塞（availableData），握手即死锁。
        let response = try await transport.receiveResponse(timeout: 5)
        #expect(response == payload)

        await transport.close()
    }

    @Test("receiveResponse times out when server never responds")
    func receiveTimeout() async throws {
        let transport = MCPStdioTransport()
        try await transport.start(command: "/bin/sleep", arguments: ["30"], environment: [:])

        // 回归：超时路径曾永久挂起（task group 等不到被挂起的 waiter）。
        await #expect(throws: MCPTransportError.timedOut) {
            _ = try await transport.receiveResponse(timeout: 0.2)
        }

        await transport.close()
    }
}
