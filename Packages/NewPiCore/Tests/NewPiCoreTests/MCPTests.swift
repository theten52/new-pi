import Foundation
import Testing
@testable import NewPiCore

@Suite("MCPJSONRPC")
struct MCPJSONRPCTests {
    @Test("encodeFrame produces newline-delimited JSON (spec)")
    func encodeFrame() {
        let payload = Data("{\"jsonrpc\":\"2.0\"}".utf8)
        let framed = MCPJSONRPC.encodeFrame(payload: payload)
        #expect(framed == payload + Data("\n".utf8))
    }

    @Test("decode single ndjson frame from buffer")
    func decodeSingleFrame() throws {
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        var buffer = MCPJSONRPC.encodeFrame(payload: payload)
        let frames = try MCPJSONRPC.decodeFrames(from: &buffer)
        #expect(frames.count == 1)
        #expect(frames[0] == payload)
        #expect(buffer.isEmpty)
    }

    @Test("incomplete ndjson line waits for more bytes")
    func incompleteFrame() throws {
        let payload = Data("{\"id\":1}".utf8)
        var buffer = Data(payload.prefix(3))
        // 没有换行符 = 帧不完整：不抛错、缓冲保留，等待更多数据。
        #expect(try MCPJSONRPC.decodeFrames(from: &buffer).isEmpty)
        #expect(buffer.count == 3)
        buffer.append(payload.dropFirst(3) + Data("\n".utf8))
        let frames = try MCPJSONRPC.decodeFrames(from: &buffer)
        #expect(frames == [payload])
        #expect(buffer.isEmpty)
    }

    @Test("accepts Content-Length framed messages (interop)")
    func decodeContentLengthFrame() throws {
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        var buffer = Data("Content-Length: \(payload.count)\r\n\r\n".utf8) + payload
        let frames = try MCPJSONRPC.decodeFrames(from: &buffer)
        #expect(frames == [payload])
        #expect(buffer.isEmpty)
    }

    @Test("content-length body split across chunks waits for more bytes")
    func contentLengthPartialBody() throws {
        let payload = Data("{\"id\":1}".utf8)
        var buffer = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        #expect(try MCPJSONRPC.decodeFrames(from: &buffer).isEmpty)
        buffer.append(payload)
        #expect(try MCPJSONRPC.decodeFrames(from: &buffer) == [payload])
    }

    @Test("garbage lines are dropped without wedging the buffer")
    func badLineRecovery() throws {
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        var buffer = Data("server log line that is not json\n".utf8)
        buffer.append(Data("\n".utf8)) // 空行
        buffer.append(payload + Data("\n".utf8))
        let frames = try MCPJSONRPC.decodeFrames(from: &buffer)
        #expect(frames == [payload])
        #expect(buffer.isEmpty)
    }

    @Test("invalid content-length header throws")
    func invalidContentLength() {
        var buffer = Data("Content-Length: not-a-number\r\n\r\n{}".utf8)
        #expect(throws: MCPJSONRPCFramingError.invalidContentLength) {
            _ = try MCPJSONRPC.decodeFrames(from: &buffer)
        }
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

    @Test("server notifications are not consumed as responses")
    func notificationsDropped() async throws {
        let transport = MCPStdioTransport()
        try await transport.start(command: "/bin/cat", arguments: [], environment: [:])

        // cat 会原样回显：先回显一条通知帧，再回显响应帧。
        // 通知必须被丢弃，否则会被 FIFO 当作响应消费，破坏配对。
        let notification = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}".utf8)
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)
        try await transport.send(frame: MCPJSONRPC.encodeFrame(payload: notification))
        try await transport.send(frame: MCPJSONRPC.encodeFrame(payload: response))

        let received = try await transport.receiveResponse(timeout: 5)
        #expect(received == response)

        await transport.close()
    }
}
