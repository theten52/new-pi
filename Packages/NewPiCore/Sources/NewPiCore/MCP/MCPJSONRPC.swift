import Foundation

public struct JSONRPCRequest: Encodable, Equatable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: JSONValue?

    init(id: Int, method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Encodable, Equatable {
    let jsonrpc: String
    let method: String
    let params: JSONValue?

    init(method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Codable, Equatable {
    let jsonrpc: String?
    let id: Int?
    let result: JSONValue?
    let error: JSONRPCErrorObject?

    init(jsonrpc: String? = "2.0", id: Int?, result: JSONValue?, error: JSONRPCErrorObject?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct JSONRPCErrorObject: Codable, Equatable {
    let code: Int
    let message: String
    let data: JSONValue?
}

public enum MCPJSONRPCFramingError: LocalizedError, Sendable, Equatable {
    case invalidHeader
    case invalidContentLength
    case incompleteFrame

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            "Invalid MCP JSON-RPC frame header"
        case .invalidContentLength:
            "Invalid MCP JSON-RPC content length"
        case .incompleteFrame:
            "Incomplete MCP JSON-RPC frame"
        }
    }
}

public enum MCPJSONRPC {
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    public static func encodeFrame(payload: Data) -> Data {
        let header = "Content-Length: \(payload.count)\r\n\r\n"
        return Data(header.utf8) + payload
    }

    public static func encodeRequest(_ request: JSONRPCRequest) throws -> Data {
        let payload = try JSONEncoder().encode(request)
        return encodeFrame(payload: payload)
    }

    public static func encodeNotification(_ notification: JSONRPCNotification) throws -> Data {
        let payload = try JSONEncoder().encode(notification)
        return encodeFrame(payload: payload)
    }

    public static func decodeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while true {
            guard let frame = try decodeNextFrame(from: &buffer) else {
                break
            }
            frames.append(frame)
        }
        return frames
    }

    private static func decodeNextFrame(from buffer: inout Data) throws -> Data? {
        guard let terminatorRange = buffer.range(of: headerTerminator) else {
            return nil
        }

        let headerData = buffer[..<terminatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MCPJSONRPCFramingError.invalidHeader
        }

        var contentLength: Int?
        for line in headerText.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("content-length:") else { continue }
            let value = trimmed.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            contentLength = Int(value)
            break
        }

        guard let contentLength, contentLength >= 0 else {
            throw MCPJSONRPCFramingError.invalidContentLength
        }

        let bodyStart = terminatorRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else {
            throw MCPJSONRPCFramingError.incompleteFrame
        }

        let frame = buffer[bodyStart..<bodyEnd]
        buffer.removeSubrange(..<bodyEnd)
        return Data(frame)
    }

    public static func decodeResponse(_ data: Data) throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: data)
    }
}
