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

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            "Invalid MCP JSON-RPC frame header"
        case .invalidContentLength:
            "Invalid MCP JSON-RPC content length"
        }
    }
}

public enum MCPJSONRPC {
    /// 单个帧/缓冲的最大字节数，防御异常服务器无界增长。
    public static let maxFrameBytes = 8 * 1024 * 1024

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let newline = Data("\n".utf8)
    private static let contentLengthPrefix = Data("content-length:".utf8)

    /// MCP 规范（2024-11-05 及之后）的 stdio 传输是换行分隔 JSON（ndjson），
    /// 发送端按规范输出 ndjson。注意部分客户端（Claude Code 等）使用 LSP 风格
    /// Content-Length 分帧，接收端两种格式都接受（见 decodeFrames）。
    public static func encodeFrame(payload: Data) -> Data {
        payload + newline
    }

    public static func encodeRequest(_ request: JSONRPCRequest) throws -> Data {
        let payload = try JSONEncoder().encode(request)
        return encodeFrame(payload: payload)
    }

    public static func encodeNotification(_ notification: JSONRPCNotification) throws -> Data {
        let payload = try JSONEncoder().encode(notification)
        return encodeFrame(payload: payload)
    }

    /// 从缓冲中解出所有完整帧。接收端同时兼容两种格式：
    /// - ndjson（规范）：逐行切分，空行与无法解析为 JSON 对象的坏行直接丢弃，
    ///   避免一次坏帧堵死后续所有帧；
    /// - Content-Length 分帧（LSP 风格，部分客户端/服务器使用）。
    /// 缓冲不足一帧时不抛错，等待更多数据；头部非法才抛错（调用方应清空缓冲恢复）。
    public static func decodeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while !buffer.isEmpty {
            if isContentLengthFramed(buffer) {
                guard let frame = try decodeContentLengthFrame(from: &buffer) else { break }
                frames.append(frame)
            } else {
                guard let newlineRange = buffer.range(of: newline) else { break }
                var line = buffer[..<newlineRange.lowerBound]
                buffer.removeSubrange(...newlineRange.lowerBound)
                if line.last == UInt8(ascii: "\r") {
                    line = line.dropLast()
                }
                // 空行与非 JSON 行（如服务器打印的日志）丢弃，继续解后续帧。
                let trimmed = line.drop(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") })
                guard !trimmed.isEmpty,
                      (try? JSONSerialization.jsonObject(with: trimmed)) != nil else { continue }
                frames.append(Data(trimmed))
            }
        }
        return frames
    }

    private static func isContentLengthFramed(_ buffer: Data) -> Bool {
        guard buffer.count >= contentLengthPrefix.count else { return false }
        return buffer.prefix(contentLengthPrefix.count).elementsEqual(contentLengthPrefix, by: {
            asciiLower($0) == asciiLower($1)
        })
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (65 ... 90).contains(byte) ? byte + 32 : byte
    }

    /// 返回 nil 表示缓冲不足一个完整帧（等待更多数据）。
    private static func decodeContentLengthFrame(from buffer: inout Data) throws -> Data? {
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

        guard let contentLength, contentLength >= 0, contentLength <= maxFrameBytes else {
            throw MCPJSONRPCFramingError.invalidContentLength
        }

        let bodyStart = terminatorRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else {
            return nil
        }

        let frame = buffer[bodyStart..<bodyEnd]
        buffer.removeSubrange(..<bodyEnd)
        return Data(frame)
    }

    public static func decodeResponse(_ data: Data) throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: data)
    }
}
