import Foundation

public enum NewPiLogLevel: String, Sendable, Equatable {
    case info = "INFO"
    case error = "ERROR"
}

public struct NewPiLogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: NewPiLogLevel
    public let category: String
    public let message: String
    public let details: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: NewPiLogLevel,
        category: String,
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.details = details
    }

    public var formattedMessage: String {
        let formatter = ISO8601DateFormatter()
        let header = "[\(formatter.string(from: timestamp))] [\(level.rawValue)] [\(category)] \(message)"
        guard let details, !details.isEmpty else {
            return header
        }
        return "\(header)\n\(details)"
    }
}

public enum NewPiLogSanitizer {
    public static func sanitize(_ value: String, secrets: [String]) -> String {
        var sanitized = value
        for secret in secrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sanitized = sanitized.replacingOccurrences(of: trimmed, with: "[redacted]")
        }

        let bearerPattern = #"(?i)\bBearer\s+[-A-Za-z0-9._~+/=]+"#
        if let expression = try? NSRegularExpression(pattern: bearerPattern) {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = expression.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "Bearer [redacted]"
            )
        }

        return sanitized
    }
}

public enum NewPiLogger {
    public typealias Handler = @Sendable (NewPiLogEntry) -> Void

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    public static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    public static func info(
        category: String,
        message: String,
        details: String? = nil,
        secrets: [String] = []
    ) {
        record(level: .info, category: category, message: message, details: details, secrets: secrets)
    }

    public static func error(
        category: String,
        message: String,
        details: String? = nil,
        secrets: [String] = []
    ) {
        record(level: .error, category: category, message: message, details: details, secrets: secrets)
    }

    public static func logLLMRequest(
        category: String,
        url: URL,
        model: String,
        requestBody: Data,
        secrets: [String] = []
    ) {
        let bodyText = prettyJSONString(from: requestBody) ?? String(data: requestBody, encoding: .utf8) ?? "<binary>"
        let sanitizedBody = NewPiLogSanitizer.sanitize(bodyText, secrets: secrets)
        let sanitizedURL = NewPiLogSanitizer.sanitize(url.absoluteString, secrets: secrets)
        // SECURITY-REVIEW: request bodies may contain prompts; secrets are redacted before logging.
        info(
            category: category,
            message: "LLM request started",
            details: """
            URL: \(sanitizedURL)
            Model: \(model)
            Request body:
            \(sanitizedBody)
            """,
            secrets: secrets
        )
    }

    public static func logLLMResponse(
        category: String,
        statusCode: Int,
        elapsedMilliseconds: Int,
        body: String,
        secrets: [String] = []
    ) {
        let sanitizedBody = NewPiLogSanitizer.sanitize(body, secrets: secrets)
        info(
            category: category,
            message: "LLM response received",
            details: """
            HTTP status: \(statusCode)
            Elapsed: \(elapsedMilliseconds)ms
            Response body:
            \(sanitizedBody)
            """,
            secrets: secrets
        )
    }

    public static func logLLMStreamFinished(category: String, model: String) {
        info(
            category: category,
            message: "LLM stream finished",
            details: "Model: \(model)"
        )
    }

    private static func record(
        level: NewPiLogLevel,
        category: String,
        message: String,
        details: String?,
        secrets: [String]
    ) {
        let sanitizedDetails = details.map { NewPiLogSanitizer.sanitize($0, secrets: secrets) }
        let entry = NewPiLogEntry(
            level: level,
            category: category,
            message: message,
            details: sanitizedDetails
        )

        lock.lock()
        let currentHandler = handler
        lock.unlock()
        currentHandler?(entry)
    }

    private static func prettyJSONString(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
