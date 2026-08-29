import Foundation

/// SECURITY-REVIEW: Sends user conversation to external OpenAI Responses-compatible HTTP endpoints.
public struct ResponsesAPIProvider: LLMProvider, Sendable {
    public var profile: ProviderProfile
    public var apiKeyProvider: @Sendable () async throws -> String
    public var session: URLSession

    public init(
        profile: ProviderProfile,
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        session: URLSession = .newPiDefault
    ) {
        self.profile = profile
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    public func stream(
        model: ModelConfig,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = try ResponsesEndpoint.resolveURL(for: profile)
                    let apiKey = try await apiKeyProvider()
                    let definition = ProviderPresetCatalog.definition(for: profile.preset)

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    ResponsesRequestPolicy.applyCommonHeaders(
                        request: &request,
                        profile: profile,
                        apiKey: apiKey,
                        definition: definition
                    )

                    var body: [String: Any] = [
                        "model": model.modelID,
                        "instructions": systemPrompt,
                        "input": ResponsesMessageEncoder.encodeInput(messages),
                        "stream": true,
                        "max_output_tokens": ResponsesRequestPolicy.effectiveMaxOutputTokens(
                            model: model,
                            profile: profile
                        ),
                        "reasoning": [
                            "effort": ResponsesRequestPolicy.reasoningEffort(
                                model: model,
                                profile: profile,
                                hasTools: !tools.isEmpty
                            ),
                        ],
                    ]

                    if !tools.isEmpty {
                        body["tools"] = ResponsesMessageEncoder.encodeTools(tools)
                        body["tool_choice"] = "auto"
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let requestBody = request.httpBody ?? Data()
                    let redactionSecrets = apiKey.isEmpty ? [] : [apiKey]
                    let startedAt = Date()
                    NewPiLogger.logLLMRequest(
                        category: "responses-api",
                        url: endpoint,
                        model: model.modelID,
                        requestBody: requestBody,
                        secrets: redactionSecrets
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let message = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                        NewPiLogger.logLLMResponse(
                            category: "responses-api",
                            statusCode: http.statusCode,
                            elapsedMilliseconds: elapsed,
                            body: message,
                            secrets: redactionSecrets
                        )
                        throw AgentError.llmFailed(message)
                    }

                    if let http = response as? HTTPURLResponse {
                        NewPiLogger.info(
                            category: "responses-api",
                            message: "LLM stream started",
                            details: "HTTP \(http.statusCode)"
                        )
                    }

                    var sseParser = SSEByteStreamParser()
                    let decoder = ResponsesSSEDecoder()
                    var parser = ResponsesStreamParser()
                    var lastUsage = UsageStats()
                    var failedMessage: String?
                    // response.completed / response.incomplete / response.failed 均为终态；
                    // 收到即主动结束，不等服务端关连接（keep-alive 会让完成状态晚 ~10s）。
                    var didReachTerminal = false

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for block in sseParser.feed(byte) {
                            let rawEvents = decoder.decodeLines(block)
                            for raw in rawEvents {
                                if case let .failed(message) = raw {
                                    failedMessage = message
                                    didReachTerminal = true
                                }
                            }
                            let parsed = parser.parse(events: rawEvents)
                            for event in parsed {
                                if case let .completed(_, usage) = event {
                                    lastUsage = usage
                                    didReachTerminal = true
                                }
                                continuation.yield(event)
                            }
                        }
                        if didReachTerminal { break }
                    }

                    for block in sseParser.finish() {
                        let rawEvents = decoder.decodeLines(block)
                        for raw in rawEvents {
                            if case let .failed(message) = raw {
                                failedMessage = message
                            }
                        }
                        let parsed = parser.parse(events: rawEvents)
                        for event in parsed {
                            if case let .completed(_, usage) = event {
                                lastUsage = usage
                            }
                            continuation.yield(event)
                        }
                    }

                    for event in parser.finish() {
                        continuation.yield(event)
                    }

                    if let failedMessage {
                        throw AgentError.llmFailed(failedMessage)
                    }

                    NewPiLogger.logLLMStreamFinished(
                        category: "responses-api",
                        model: model.modelID,
                        usage: lastUsage
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentError.aborted)
                } catch let error as AgentError {
                    NewPiLogger.error(
                        category: "responses-api",
                        message: "LLM request failed",
                        details: error.localizedDescription
                    )
                    continuation.finish(throwing: error)
                } catch {
                    NewPiLogger.error(
                        category: "responses-api",
                        message: "LLM request failed",
                        details: error.localizedDescription
                    )
                    continuation.finish(throwing: AgentError.llmFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
