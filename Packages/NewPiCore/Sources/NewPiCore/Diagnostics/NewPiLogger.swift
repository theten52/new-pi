import Foundation

public enum NewPiLogLevel: String, Sendable, Equatable {
    case debug = "DEBUG"
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
    /// Precomputed once at creation so repeated `logText` assembly is cheap.
    public let formattedMessage: String

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
        let header = "[\(Self.formattedTimestamp(timestamp))] [\(level.rawValue)] [\(category)] \(message)"
        if let details, !details.isEmpty {
            self.formattedMessage = "\(header)\n\(details)"
        } else {
            self.formattedMessage = header
        }
    }

    /// Thread-safe shared formatter so we do not allocate a new `ISO8601DateFormatter`
    /// for every log entry (a notable cost when assembling large log views).
    private nonisolated(unsafe) static let timestampFormatter = ISO8601DateFormatter()
    private static let timestampFormatterLock = NSLock()

    private static func formattedTimestamp(_ date: Date) -> String {
        timestampFormatterLock.lock()
        defer { timestampFormatterLock.unlock() }
        return timestampFormatter.string(from: date)
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

        let apiKeyPattern = #"(?i)(api[_-]?key|x-api-key|authorization)\s*[:=]\s*["']?[-A-Za-z0-9._~+/=]{8,}"#
        if let expression = try? NSRegularExpression(pattern: apiKeyPattern) {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = expression.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "$1: [redacted]"
            )
        }

        return sanitized
    }
}

public enum NewPiLogger {
    public typealias Handler = @Sendable (NewPiLogEntry) -> Void

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?
    private nonisolated(unsafe) static var fileLoggingEnabled = false

    public static var logFileURLs: [URL] {
        NewPiFileLogSink.shared.activeLogURLs
    }

    public static var globalLogFileURL: URL {
        NewPiFileLogSink.shared.globalLogURL
    }

    /// Enables append-only file logging under `~/.new-pi/agent/logs/newpi-debug.log`.
    public static func bootstrapFileLogging(sessionID: String = UUID().uuidString) {
        lock.lock()
        fileLoggingEnabled = true
        lock.unlock()
        NewPiFileLogSink.shared.enable(sessionID: sessionID)
    }

    public static func setProjectLogDirectory(_ url: URL?) {
        NewPiFileLogSink.shared.setProjectDirectory(url)
        if let url {
            info(
                category: "lifecycle",
                message: "Project log attached",
                details: "Project: \(url.path)\nLog: \(NewPiFileLogSink.shared.projectLogURL(for: url).path)"
            )
        }
    }

    public static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    public static func debug(
        category: String,
        message: String,
        details: String? = nil,
        secrets: [String] = []
    ) {
        record(level: .debug, category: category, message: message, details: details, secrets: secrets)
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

    public static func logLLMStreamFinished(
        category: String,
        model: String,
        usage: UsageStats? = nil
    ) {
        var details = "Model: \(model)"
        if let usage {
            details += """

            prompt_tokens=\(usage.inputTokens)
            completion_tokens=\(usage.outputTokens)
            """
        }
        info(
            category: category,
            message: "LLM stream finished",
            details: details
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
        let writeToFile = fileLoggingEnabled
        lock.unlock()

        currentHandler?(entry)
        if writeToFile {
            NewPiFileLogSink.shared.append(entry)
        }
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
