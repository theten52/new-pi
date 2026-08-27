import Foundation

public enum OpenAICompatibleEndpoint {
    public static func resolveURL(for profile: ProviderProfile) throws -> URL {
        let definition = ProviderPresetCatalog.definition(for: profile.preset)
        let raw = profile.option(.baseURL) ?? definition.defaultBaseURL ?? ""

        switch profile.preset {
        case .ollama:
            let base = raw.isEmpty ? "http://127.0.0.1:11434" : raw
            let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(trimmed)/v1/chat/completions") else {
                throw ProviderConfigError.invalidURL(base)
            }
            return url
        case .openai, .openRouter, .openaiCompatible:
            if raw.contains("/chat/completions") {
                guard let url = URL(string: raw) else {
                    throw ProviderConfigError.invalidURL(raw)
                }
                return url
            }
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fallback = definition.defaultBaseURL ?? "https://api.openai.com/v1/chat/completions"
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
                encoded.append(["role": "user", "content": user.content])
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
}

public enum OpenAIStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsDelta: String?)
    case completed(reason: String?, inputTokens: Int, outputTokens: Int)
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
            case let .completed(reason, inputTokens, outputTokens):
                let hadToolCalls = !toolIDs.isEmpty
                output.append(contentsOf: flushToolCalls())
                var stopReason = mapStopReason(reason)
                if hadToolCalls, stopReason != .toolUse {
                    // Some OpenAI-compatible providers (e.g. DeepSeek) emit finish_reason=stop
                    // even when tool_calls were streamed.
                    stopReason = .toolUse
                }
                let usage = UsageStats(inputTokens: inputTokens, outputTokens: outputTokens)
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
                    events.append(
                        .completed(
                            reason: finishReason,
                            inputTokens: usageJSON?["prompt_tokens"] as? Int ?? 0,
                            outputTokens: usageJSON?["completion_tokens"] as? Int ?? 0
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
                do {
                    let endpoint = try OpenAICompatibleEndpoint.resolveURL(for: profile)
                    let apiKey = try await apiKeyProvider()

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let definition = ProviderPresetCatalog.definition(for: profile.preset)
                    if definition.credentialRequired, !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

                    OpenAICompatibleRequestPolicy.applyDeepSeekThinkingPolicy(
                        body: &body,
                        model: model,
                        profile: profile,
                        hasTools: !tools.isEmpty
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

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let message = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
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

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for block in sseParser.feed(byte) {
                            let parsed = parser.parse(events: decoder.decodeLines(block))
                            for event in parsed {
                                if case let .completed(_, usage) = event {
                                    lastUsage = usage
                                }
                                continuation.yield(event)
                            }
                        }
                    }

                    for block in sseParser.finish() {
                        let parsed = parser.parse(events: decoder.decodeLines(block))
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

                    NewPiLogger.logLLMStreamFinished(
                        category: "openai-compatible",
                        model: model.modelID,
                        usage: lastUsage
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentError.aborted)
                } catch let error as AgentError {
                    NewPiLogger.error(
                        category: "openai-compatible",
                        message: "LLM request failed",
                        details: error.localizedDescription
                    )
                    continuation.finish(throwing: error)
                } catch {
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

    /// DeepSeek V4 thinking tokens share the completion budget with content/tool calls.
    /// Disable thinking for tool-using coding-agent requests so output budget remains usable.
    static func applyDeepSeekThinkingPolicy(
        body: inout [String: Any],
        model: ModelConfig,
        profile: ProviderProfile,
        hasTools: Bool
    ) {
        guard isDeepSeekModel(model.modelID, profile: profile), hasTools else { return }
        body["thinking"] = ["type": "disabled"]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
