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
                // do / catch 共享的指标计时器与状态码（catch 分支也要上报）。
                var perf = LLMRequestTiming()
                var httpStatus: Int?
                do {
                    let endpoint = try ResponsesEndpoint.resolveURL(for: profile)
                    let apiKey = try await apiKeyProvider()

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    ResponsesRequestPolicy.applyCommonHeaders(
                        request: &request,
                        profile: profile,
                        apiKey: apiKey
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
                            "effort": ResponsesRequestPolicy.reasoningEffort(model: model),
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
                    perf.markResponse()
                    httpStatus = (response as? HTTPURLResponse)?.statusCode
                    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let message = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                        perf.markEnd()
                        await LLMMetricsRecorder.shared.record(metric(
                            timing: perf,
                            statusCode: http.statusCode,
                            usage: UsageStats(),
                            errorType: "http_error",
                            errorMessage: String(message.prefix(500)),
                            model: model,
                            hasTools: !tools.isEmpty
                        ))
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
                                switch raw {
                                case .textDone:
                                    perf.markTextDone()
                                case .completed:
                                    perf.markTerminal()
                                case let .failed(message):
                                    perf.markTerminal()
                                    failedMessage = message
                                    didReachTerminal = true
                                default:
                                    break
                                }
                            }
                            let parsed = parser.parse(events: rawEvents)
                            for event in parsed {
                                switch event {
                                case .textDelta: perf.markText()
                                case .thinkingDelta: perf.markThinking()
                                default: break
                                }
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
                            switch raw {
                            case .textDone:
                                perf.markTextDone()
                            case .completed:
                                perf.markTerminal()
                            case let .failed(message):
                                perf.markTerminal()
                                failedMessage = message
                            default:
                                break
                            }
                        }
                        let parsed = parser.parse(events: rawEvents)
                        for event in parsed {
                            switch event {
                            case .textDelta: perf.markText()
                            case .thinkingDelta: perf.markThinking()
                            default: break
                            }
                            if case let .completed(_, usage) = event {
                                lastUsage = usage
                            }
                            continuation.yield(event)
                        }
                    }

                    for event in parser.finish() {
                        switch event {
                        case .textDelta: perf.markText()
                        case .thinkingDelta: perf.markThinking()
                        default: break
                        }
                        continuation.yield(event)
                    }

                    if let failedMessage {
                        perf.markEnd()
                        await LLMMetricsRecorder.shared.record(metric(
                            timing: perf,
                            statusCode: httpStatus,
                            usage: lastUsage,
                            errorType: "llm_error",
                            errorMessage: String(failedMessage.prefix(500)),
                            model: model,
                            hasTools: !tools.isEmpty
                        ))
                        throw AgentError.llmFailed(failedMessage)
                    }

                    perf.markEnd()
                    await LLMMetricsRecorder.shared.record(metric(
                        timing: perf,
                        statusCode: httpStatus,
                        usage: lastUsage,
                        errorType: nil,
                        errorMessage: nil,
                        model: model,
                        hasTools: !tools.isEmpty
                    ))
                    NewPiLogger.logLLMStreamFinished(
                        category: "responses-api",
                        model: model.modelID,
                        usage: lastUsage
                    )
                    continuation.finish()
                } catch is CancellationError {
                    perf.markEnd()
                    await LLMMetricsRecorder.shared.record(metric(
                        timing: perf,
                        statusCode: httpStatus,
                        usage: UsageStats(),
                        errorType: "cancelled",
                        errorMessage: nil,
                        model: model,
                        hasTools: !tools.isEmpty
                    ))
                    continuation.finish(throwing: AgentError.aborted)
                } catch let error as AgentError {
                    perf.markEnd()
                    await LLMMetricsRecorder.shared.record(metric(
                        timing: perf,
                        statusCode: httpStatus,
                        usage: UsageStats(),
                        errorType: "llm_error",
                        errorMessage: String(error.localizedDescription.prefix(500)),
                        model: model,
                        hasTools: !tools.isEmpty
                    ))
                    NewPiLogger.error(
                        category: "responses-api",
                        message: "LLM request failed",
                        details: error.localizedDescription
                    )
                    continuation.finish(throwing: error)
                } catch {
                    perf.markEnd()
                    await LLMMetricsRecorder.shared.record(metric(
                        timing: perf,
                        statusCode: httpStatus,
                        usage: UsageStats(),
                        errorType: "network",
                        errorMessage: String(error.localizedDescription.prefix(500)),
                        model: model,
                        hasTools: !tools.isEmpty
                    ))
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

    /// 构造一次请求的指标（供流式循环各出口上报）。mode 固定 responses。
    private func metric(
        timing: LLMRequestTiming,
        statusCode: Int?,
        usage: UsageStats,
        errorType: String?,
        errorMessage: String?,
        model: ModelConfig,
        hasTools: Bool
    ) -> LLMRequestMetric {
        let cost = LLMRequestMetric.estimatedCost(
            inputTokens: usage.inputTokens,
            cachedTokens: usage.cacheReadTokens,
            cacheCreation: usage.cacheCreationTokens,
            outputTokens: usage.outputTokens,
            pricing: profile.modelDefinition(for: model.modelID)?.pricing
        )
        return LLMRequestMetric(
            startedAt: timing.startedAt,
            providerName: profile.name,
            preset: profile.preset.rawValue,
            vendor: LLMMetricVendor.name(for: profile.preset.rawValue, baseURL: profile.option(.baseURL), model: model.modelID),
            model: model.modelID,
            mode: "responses",
            thinkingLevel: model.thinkingLevel == .off ? nil : model.thinkingLevel.rawValue,
            hasTools: hasTools,
            responseAt: timing.responseAt,
            firstThinkingAt: timing.firstThinkingAt,
            lastThinkingAt: timing.lastThinkingAt,
            firstTextAt: timing.firstTextAt,
            lastTextAt: timing.lastTextAt,
            textDoneAt: timing.textDoneAt,
            terminalAt: timing.terminalAt,
            endedAt: timing.endedAt,
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cacheReadTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            outputTokens: usage.outputTokens,
            contextWindow: profile.contextWindow(for: model.modelID),
            textDeltaCount: timing.textDeltaCount,
            thinkingDeltaCount: timing.thinkingDeltaCount,
            statusCode: statusCode,
            errorType: errorType,
            errorMessage: errorMessage,
            costAmount: cost?.amount,
            costCurrency: cost?.currency
        )
    }
}
