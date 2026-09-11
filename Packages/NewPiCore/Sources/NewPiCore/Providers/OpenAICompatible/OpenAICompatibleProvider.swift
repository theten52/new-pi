import Foundation

public enum OpenAICompatibleEndpoint {
    public static func resolveURL(for profile: ProviderProfile) throws -> URL {
        let raw = profile.option(.baseURL) ?? profile.preset.defaultBaseURL ?? ""

        switch profile.preset {
        case .ollama:
            let base = raw.isEmpty ? "http://127.0.0.1:11434" : raw
            let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(trimmed)/v1/chat/completions") else {
                throw ProviderConfigError.invalidURL(base)
            }
            return url
        case .openai, .openRouter, .openaiCompatible, .xiaomiMiMo:
            if raw.contains("/chat/completions") {
                guard let url = URL(string: raw) else {
                    throw ProviderConfigError.invalidURL(raw)
                }
                return url
            }
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fallback = profile.preset.defaultBaseURL ?? "https://api.openai.com/v1/chat/completions"
            let composed = trimmed.isEmpty ? fallback : "\(trimmed)/v1/chat/completions"
            guard let url = URL(string: composed) else {
                throw ProviderConfigError.invalidURL(composed)
            }
            return url
        case .anthropic:
            throw AgentError.invalidState("Anthropic preset must use AnthropicProvider")
        }
    }
}

public enum OpenAIMessageEncoder {
    public static func encodeMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var encoded: [[String: Any]] = []

        for message in messages {
            switch message {
            case let .user(user):
                encoded.append(["role": "user", "content": userContentPayload(user)])
            case let .assistant(assistant):
                var payload: [String: Any] = ["role": "assistant"]
                if assistant.toolCalls.isEmpty {
                    payload["content"] = assistant.text
                } else {
                    payload["content"] = assistant.text.nilIfEmpty as Any
                    payload["tool_calls"] = assistant.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": (try? String(data: call.arguments.toJSONData(), encoding: .utf8)) ?? "{}",
                            ],
                        ] as [String: Any]
                    }
                }
                if !assistant.reasoningContent.isEmpty {
                    payload["reasoning_content"] = assistant.reasoningContent
                }
                encoded.append(payload)
            case let .toolResult(toolResult):
                encoded.append([
                    "role": "tool",
                    "tool_call_id": toolResult.toolCallID,
                    "content": toolResult.content,
                ])
            case let .compactionSummary(summary):
                encoded.append([
                    "role": "user",
                    "content": "Conversation summary:\n\(summary)",
                ])
            }
        }

        return encoded
    }

    public static func encodeTools(_ tools: [ToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": (try? tool.parameters.toJSONObject()) ?? [
                        "type": "object",
                        "properties": [:],
                    ],
                ],
            ] as [String: Any]
        }
    }

    /// 用户消息内容：无附件时保持纯字符串；有附件时升级为
    /// `[{type:"text"},{type:"image_url",image_url:{url:"data:<mime>;base64,…"}}]`。
    private static func userContentPayload(_ user: UserMessage) -> Any {
        guard !user.attachments.isEmpty else { return user.content }
        var blocks: [[String: Any]] = []
        if !user.content.isEmpty {
            blocks.append(["type": "text", "text": user.content])
        }
        for attachment in user.attachments {
            guard let data = SessionAttachments.data(for: attachment) else { continue }
            let dataURL = "data:\(attachment.mediaType);base64,\(data.base64EncodedString())"
            blocks.append([
                "type": "image_url",
                "image_url": ["url": dataURL],
            ])
            // 缩放/坐标映射说明（BACKLOG-IMAGE-INPUT）：紧跟 image_url 块以 text 块下发。
            if let note = attachment.note, !note.isEmpty {
                blocks.append(["type": "text", "text": note])
            }
        }
        return blocks
    }
}

public enum OpenAIStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsDelta: String?)
    case completed(reason: String?, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0)
}

public struct OpenAIStreamParser: Sendable {
    private var toolIDs: [Int: String] = [:]
    private var toolNames: [Int: String] = [:]
    private var toolArguments: [Int: String] = [:]

    public init() {}

    public mutating func parse(events: [OpenAIStreamEvent]) -> [LLMStreamEvent] {
        var output: [LLMStreamEvent] = []

        for event in events {
            switch event {
            case let .textDelta(text):
                output.append(.textDelta(text))
            case let .reasoningDelta(text):
                output.append(.thinkingDelta(text))
            case let .toolCallDelta(index, id, name, argumentsDelta):
                if let id { toolIDs[index] = id }
                if let name { toolNames[index] = name }
                if let argumentsDelta {
                    toolArguments[index, default: ""] += argumentsDelta
                }
            case let .completed(reason, inputTokens, outputTokens, cacheReadTokens):
                let hadToolCalls = !toolIDs.isEmpty
                output.append(contentsOf: flushToolCalls())
                var stopReason = mapStopReason(reason)
                if hadToolCalls, stopReason != .toolUse {
                    // Some OpenAI-compatible providers (e.g. DeepSeek) emit finish_reason=stop
                    // even when tool_calls were streamed.
                    stopReason = .toolUse
                }
                let usage = UsageStats(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens)
                output.append(.completed(stopReason: stopReason, usage: usage))
            }
        }

        return output
    }

    /// Emits any pending tool calls. Call at stream end if no terminal `completed` event arrived.
    public mutating func finish() -> [LLMStreamEvent] {
        flushToolCalls()
    }

    private mutating func flushToolCalls() -> [LLMStreamEvent] {
        var output: [LLMStreamEvent] = []
        for index in toolIDs.keys.sorted() {
            guard let id = toolIDs[index], let name = toolNames[index] else { continue }
            let json = toolArguments[index] ?? "{}"
            let arguments = (try? JSONValueDecoder.decode(from: json)) ?? .object([:])
            output.append(.toolCall(ToolCallContent(id: id, name: name, arguments: arguments)))
        }
        toolIDs.removeAll()
        toolNames.removeAll()
        toolArguments.removeAll()
        return output
    }

    private func mapStopReason(_ reason: String?) -> StopReason {
        switch reason {
        case "tool_calls":
            return .toolUse
        case "length":
            return .length
        default:
            return .stop
        }
    }
}

public struct OpenAISSEDecoder: Sendable {
    public init() {}

    public func decodeLines(_ lines: [String]) -> [OpenAIStreamEvent] {
        var events: [OpenAIStreamEvent] = []

        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
                if let delta = choice["delta"] as? [String: Any] {
                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        events.append(.reasoningDelta(reasoning))
                    }
                    if let content = delta["content"] as? String, !content.isEmpty {
                        events.append(.textDelta(content))
                    }
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for toolCall in toolCalls {
                            let index = toolCall["index"] as? Int ?? 0
                            let id = toolCall["id"] as? String
                            let function = toolCall["function"] as? [String: Any]
                            let name = function?["name"] as? String
                            let arguments = function?["arguments"] as? String
                            events.append(.toolCallDelta(index: index, id: id, name: name, argumentsDelta: arguments))
                        }
                    }
                }
                if let finishReason = choice["finish_reason"] as? String {
                    let usageJSON = json["usage"] as? [String: Any]
                    let promptTokens = usageJSON?["prompt_tokens"] as? Int ?? 0
                    // 缓存命中：OpenAI 为 prompt_tokens_details.cached_tokens；
                    // DeepSeek 为 prompt_cache_hit_tokens。
                    let details = usageJSON?["prompt_tokens_details"] as? [String: Any]
                    let cached = details?["cached_tokens"] as? Int
                        ?? usageJSON?["prompt_cache_hit_tokens"] as? Int
                        ?? 0
                    events.append(
                        .completed(
                            reason: finishReason,
                            // 归一化语义：inputTokens 不含缓存命中部分（与 Anthropic 一致）。
                            inputTokens: max(0, promptTokens - cached),
                            outputTokens: usageJSON?["completion_tokens"] as? Int ?? 0,
                            cacheReadTokens: cached
                        )
                    )
                }
            }
        }

        return events
    }
}

/// SECURITY-REVIEW: Sends user conversation to external OpenAI-compatible HTTP endpoints.
public struct OpenAICompatibleProvider: LLMProvider, Sendable {
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
                    let endpoint = try OpenAICompatibleEndpoint.resolveURL(for: profile)
                    let apiKey = try await apiKeyProvider()

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    if profile.preset.credentialRequired, !apiKey.isEmpty {
                        request.setValue(profile.apiKeyHeaderValue(apiKey), forHTTPHeaderField: profile.apiKeyHeader)
                    }

                    if let organization = profile.option(.organization) {
                        request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
                    }
                    if let referer = profile.option(.httpReferer) {
                        request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
                    }
                    if let title = profile.option(.appTitle) {
                        request.setValue(title, forHTTPHeaderField: "X-Title")
                    }

                    var body: [String: Any] = [
                        "model": model.modelID,
                        "max_tokens": OpenAICompatibleRequestPolicy.effectiveMaxTokens(
                            model: model,
                            profile: profile
                        ),
                        "stream": true,
                        "messages": [["role": "system", "content": systemPrompt]]
                            + OpenAIMessageEncoder.encodeMessages(messages),
                    ]

                    if !tools.isEmpty {
                        body["tools"] = OpenAIMessageEncoder.encodeTools(tools)
                    }

                    OpenAICompatibleRequestPolicy.applyThinkingPolicy(
                        body: &body,
                        model: model,
                        profile: profile
                    )

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let requestBody = request.httpBody ?? Data()
                    let redactionSecrets = apiKey.isEmpty ? [] : [apiKey]
                    let startedAt = Date()
                    NewPiLogger.logLLMRequest(
                        category: "openai-compatible",
                        url: endpoint,
                        model: model.modelID,
                        requestBody: requestBody,
                        secrets: redactionSecrets
                    )

                    perf.markRequestSent()
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
                            category: "openai-compatible",
                            statusCode: http.statusCode,
                            elapsedMilliseconds: elapsed,
                            body: message,
                            secrets: redactionSecrets
                        )
                        throw AgentError.llmFailed(message)
                    }

                    if let http = response as? HTTPURLResponse {
                        NewPiLogger.info(
                            category: "openai-compatible",
                            message: "LLM stream started",
                            details: "HTTP \(http.statusCode)"
                        )
                    }

                    var sseParser = SSEByteStreamParser()
                    let decoder = OpenAISSEDecoder()
                    var parser = OpenAIStreamParser()
                    var lastUsage = UsageStats()
                    // 收到 finish_reason 块（.completed）即主动结束，不等服务端关连接
                    //（keep-alive 会让完成状态晚 ~10s）。注意：若未来开启
                    // stream_options.include_usage，usage 会落在 finish 之后的独立块，
                    // 届时需改为收到 usage 块或 [DONE] 再结束。
                    var didComplete = false

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for block in sseParser.feed(byte) {
                            let parsed = parser.parse(events: decoder.decodeLines(block))
                            for event in parsed {
                                switch event {
                                case .textDelta: perf.markText()
                                case .thinkingDelta: perf.markThinking()
                                default: break
                                }
                                if case let .completed(_, usage) = event {
                                    lastUsage = usage
                                    didComplete = true
                                }
                                continuation.yield(event)
                            }
                        }
                        if didComplete { break }
                    }

                    for block in sseParser.finish() {
                        let parsed = parser.parse(events: decoder.decodeLines(block))
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
                        category: "openai-compatible",
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
                        category: "openai-compatible",
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
                        category: "openai-compatible",
                        message: "LLM request failed",
                        details: error.localizedDescription
                    )
                    continuation.finish(throwing: AgentError.llmFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 构造一次请求的指标（供流式循环各出口上报）。
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
            runID: timing.runID,
            startedAt: timing.startedAt,
            providerName: profile.name,
            preset: profile.preset.rawValue,
            vendor: LLMMetricVendor.name(for: profile.preset.rawValue, baseURL: profile.option(.baseURL), model: model.modelID),
            model: model.modelID,
            mode: profile.apiMode == .responses ? "responses" : "chat",
            thinkingLevel: model.thinkingLevel == .off ? nil : model.thinkingLevel.rawValue,
            hasTools: hasTools,
            responseAt: timing.responseAt,
            firstThinkingAt: timing.firstThinkingAt,
            lastThinkingAt: timing.lastThinkingAt,
            firstTextAt: timing.firstTextAt,
            lastTextAt: timing.lastTextAt,
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

enum OpenAICompatibleRequestPolicy {
    private static let deepSeekMinimumMaxTokens = 16_384

    static func isDeepSeekModel(_ modelID: String, profile: ProviderProfile) -> Bool {
        let normalizedModel = modelID.lowercased()
        if normalizedModel.contains("deepseek") {
            return true
        }

        let baseURL = profile.option(.baseURL)?.lowercased() ?? ""
        return baseURL.contains("deepseek.com")
    }

    static func effectiveMaxTokens(model: ModelConfig, profile: ProviderProfile) -> Int {
        guard isDeepSeekModel(model.modelID, profile: profile) else {
            return model.maxTokens
        }
        return max(model.maxTokens, deepSeekMinimumMaxTokens)
    }

    /// OpenAI 兼容 chat 路径的思考控制（兼容/特化各家语言，均经实测）：
    /// - GLM（bigmodel.cn）：`reasoning_effort` low/medium/high 真分档；`thinking disabled` 可关
    /// - MiMo（xiaomimimo.com）：`thinking disabled` 可关；`reasoning_effort` 被接受
    /// - DeepSeek（deepseek.com）：chat 兼容端点同支持 `reasoning_effort` 分档 + `thinking disabled`
    ///   （V4/legacy 都接受，实测 effort high 会显著增加思考量并占满 completion 预算）
    /// - unknown：保守不发，避免个别服务端对未知字段报错
    ///
    /// ThinkingLevel=off → 关闭思考；low/medium/high → reasoning_effort 档位。
    /// 不做「带工具就禁用」的一刀切（旧 DeepSeek hack 已移除），思考档位完全由用户配置决定。
    ///
    /// 注：DeepSeek 走 Responses API 时由 `ResponsesRequestPolicy.reasoningEffort` 处理
    /// （`reasoning.effort`），本 policy 只覆盖 OpenAI 兼容 chat 端点。
    static func applyThinkingPolicy(
        body: inout [String: Any],
        model: ModelConfig,
        profile: ProviderProfile
    ) {
        switch detectVendor(model.modelID, profile: profile) {
        case .glm, .mimo, .deepseek:
            if model.thinkingLevel == .off {
                body["thinking"] = ["type": "disabled"]
            } else if let effort = model.thinkingLevel.reasoningEffort {
                body["reasoning_effort"] = effort
            }
        case .unknown:
            break
        }
    }

    /// OpenAI 兼容 chat 厂商嗅探：baseURL 优先，modelID 兜底。
    static func detectVendor(_ modelID: String, profile: ProviderProfile) -> OpenAICompatibleVendor {
        let model = modelID.lowercased()
        let base = profile.option(.baseURL)?.lowercased() ?? ""
        if base.contains("bigmodel.cn") || base.contains("z.ai") {
            return .glm
        }
        if base.contains("xiaomimimo.com") || model.contains("mimo") {
            return .mimo
        }
        if base.contains("deepseek.com") || model.contains("deepseek") {
            return .deepseek
        }
        return .unknown
    }
}

/// OpenAI 兼容 chat 厂商分类（思考参数语言不同，需要特化）。
public enum OpenAICompatibleVendor: Sendable {
    case deepseek
    case glm
    case mimo
    case unknown
}

extension ThinkingLevel {
    /// OpenAI 兼容 `reasoning_effort` 档位（minimal 并入 low）。off 无档位（走关闭）。
    var reasoningEffort: String? {
        switch self {
        case .off: nil
        case .minimal, .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
