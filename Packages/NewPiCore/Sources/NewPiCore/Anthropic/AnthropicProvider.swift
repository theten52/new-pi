import Foundation

public enum AnthropicAPI {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let anthropicVersion = "2023-06-01"
}

public enum AnthropicMessageEncoder {
    public static func encodeMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var encoded: [[String: Any]] = []
        var pendingToolResults: [ToolResultMessage] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            encoded.append([
                "role": "user",
                "content": pendingToolResults.map { toolResultPayload($0) },
            ])
            pendingToolResults.removeAll()
        }

        for message in messages {
            switch message {
            case let .user(user):
                flushToolResults()
                encoded.append([
                    "role": "user",
                    "content": user.content,
                ])
            case let .assistant(assistant):
                flushToolResults()
                encoded.append([
                    "role": "assistant",
                    "content": assistantPayload(assistant),
                ])
            case let .toolResult(toolResult):
                pendingToolResults.append(toolResult)
            case let .compactionSummary(summary):
                flushToolResults()
                encoded.append([
                    "role": "user",
                    "content": "Conversation summary:\n\(summary)",
                ])
            }
        }

        flushToolResults()
        return encoded
    }

    public static func encodeTools(_ tools: [ToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": (try? tool.parameters.toJSONObject()) ?? [
                    "type": "object",
                    "properties": [:],
                ],
            ]
        }
    }

    private static func assistantPayload(_ assistant: AssistantMessage) -> Any {
        var blocks: [[String: Any]] = []
        // 开启 extended thinking 时，历史 assistant 轮次须原样带回 thinking
        // block（含签名），否则 API 400。无签名的旧会话记录无法合法回放，跳过。
        if !assistant.reasoningContent.isEmpty, !assistant.reasoningSignature.isEmpty {
            blocks.append([
                "type": "thinking",
                "thinking": assistant.reasoningContent,
                "signature": assistant.reasoningSignature,
            ])
        }
        if !assistant.text.isEmpty {
            blocks.append([
                "type": "text",
                "text": assistant.text,
            ])
        }
        for call in assistant.toolCalls {
            blocks.append([
                "type": "tool_use",
                "id": call.id,
                "name": call.name,
                "input": (try? call.arguments.toJSONObject()) ?? [:],
            ])
        }
        if blocks.isEmpty {
            return ""
        }
        if blocks.count == 1, let text = blocks.first?["text"] as? String, blocks.first?["type"] as? String == "text" {
            return text
        }
        return blocks
    }

    private static func toolResultPayload(_ toolResult: ToolResultMessage) -> [String: Any] {
        [
            "type": "tool_result",
            "tool_use_id": toolResult.toolCallID,
            "content": toolResult.content,
            "is_error": toolResult.isError,
        ]
    }
}

public struct AnthropicStreamParser: Sendable {
    // 跨 SSE 块保持状态：生产路径按块调用 parse，toolInputs/stopReason/usage
    // 若在函数内局部化会在块间丢失（工具调用永远拼不出完整 JSON）。
    private var toolInputs: [String: String] = [:]
    private var stopReason: StopReason = .stop
    private var usage = UsageStats()
    private var didEmitCompleted = false

    public init() {}

    public mutating func parse(events: [AnthropicStreamEvent]) -> [LLMStreamEvent] {
        var output: [LLMStreamEvent] = []

        for event in events {
            switch event {
            case let .textDelta(text):
                output.append(.textDelta(text))
            case let .thinkingDelta(text):
                output.append(.thinkingDelta(text))
            case let .thinkingSignature(signature):
                output.append(.thinkingSignature(signature))
            case let .toolInputDelta(id, _, partialJSON):
                toolInputs[id, default: ""] += partialJSON
            case let .contentBlockStop(id, name, input):
                let arguments: JSONValue
                if let input {
                    arguments = input
                } else if let json = toolInputs[id], !json.isEmpty {
                    arguments = (try? JSONValueDecoder.decode(from: json)) ?? .object([:])
                } else {
                    arguments = .object([:])
                }
                output.append(.toolCall(ToolCallContent(id: id, name: name, arguments: arguments)))
            case let .messageDelta(reason, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens):
                if reason != nil {
                    stopReason = mapStopReason(reason)
                }
                // message_start（输入/cache）与 message_delta（输出）分两次上报，
                // 单调取 max 合并，避免后到的缺省 0 覆盖先到的真实值。
                usage.inputTokens = max(usage.inputTokens, inputTokens)
                usage.outputTokens = max(usage.outputTokens, outputTokens)
                usage.cacheReadTokens = max(usage.cacheReadTokens, cacheReadTokens)
                usage.cacheCreationTokens = max(usage.cacheCreationTokens, cacheCreationTokens)
                if reason != nil {
                    output.append(completedEvent())
                }
            }
        }

        return output
    }

    /// 流结束时调用：若 message_delta 未携带 stop_reason（异常截断等），
    /// 补发一个携带最终状态的 .completed，保证事件流恰有一次完成事件。
    public mutating func finish() -> [LLMStreamEvent] {
        didEmitCompleted ? [] : [completedEvent()]
    }

    private mutating func completedEvent() -> LLMStreamEvent {
        didEmitCompleted = true
        return .completed(stopReason: stopReason, usage: usage)
    }

    private func mapStopReason(_ reason: String?) -> StopReason {
        switch reason {
        case "tool_use":
            return .toolUse
        case "max_tokens":
            return .length
        case "end_turn", "stop_sequence", .none:
            return .stop
        default:
            return .stop
        }
    }
}

public enum AnthropicStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case thinkingSignature(String)
    case toolInputDelta(id: String, name: String, partialJSON: String)
    case contentBlockStop(id: String, name: String, input: JSONValue?)
    case messageDelta(
        reason: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    )
}

public struct AnthropicSSEDecoder: Sendable {
    // 跨 SSE 块保持状态：content_block_start 登记的 openToolBlocks 必须在
    // 后续块的 input_json_delta / content_block_stop 中仍然可见。
    private var currentEventName: String?
    private var openToolBlocks: [Int: (id: String, name: String)] = [:]

    public init() {}

    public mutating func decodeLines(_ lines: [String]) -> [AnthropicStreamEvent] {
        var events: [AnthropicStreamEvent] = []

        for line in lines {
            if line.hasPrefix("event:") {
                currentEventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }

            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            switch currentEventName {
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use",
                   let index = json["index"] as? Int,
                   let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    openToolBlocks[index] = (id, name)
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    switch delta["type"] as? String {
                    case "text_delta":
                        if let text = delta["text"] as? String {
                            events.append(.textDelta(text))
                        }
                    case "thinking_delta":
                        if let thinking = delta["thinking"] as? String {
                            events.append(.thinkingDelta(thinking))
                        }
                    case "signature_delta":
                        if let signature = delta["signature"] as? String {
                            events.append(.thinkingSignature(signature))
                        }
                    case "input_json_delta":
                        if let index = json["index"] as? Int,
                           let partial = delta["partial_json"] as? String,
                           let block = openToolBlocks[index] {
                            events.append(.toolInputDelta(id: block.id, name: block.name, partialJSON: partial))
                        }
                    default:
                        break
                    }
                }
            case "content_block_stop":
                if let index = json["index"] as? Int, let block = openToolBlocks[index] {
                    events.append(.contentBlockStop(id: block.id, name: block.name, input: nil))
                    openToolBlocks.removeValue(forKey: index)
                }
            // message_start 携带本次请求的输入/cache 用量（cache_read/cache_creation 只在这里出现）。
            case "message_start":
                let usageJSON = (json["message"] as? [String: Any])?["usage"] as? [String: Any]
                events.append(
                    .messageDelta(
                        reason: nil,
                        inputTokens: usageJSON?["input_tokens"] as? Int ?? 0,
                        outputTokens: usageJSON?["output_tokens"] as? Int ?? 0,
                        cacheReadTokens: usageJSON?["cache_read_input_tokens"] as? Int ?? 0,
                        cacheCreationTokens: usageJSON?["cache_creation_input_tokens"] as? Int ?? 0
                    )
                )
            case "message_delta":
                let delta = json["delta"] as? [String: Any]
                let usageJSON = json["usage"] as? [String: Any]
                events.append(
                    .messageDelta(
                        reason: delta?["stop_reason"] as? String,
                        inputTokens: usageJSON?["input_tokens"] as? Int ?? 0,
                        outputTokens: usageJSON?["output_tokens"] as? Int ?? 0,
                        cacheReadTokens: usageJSON?["cache_read_input_tokens"] as? Int ?? 0,
                        cacheCreationTokens: usageJSON?["cache_creation_input_tokens"] as? Int ?? 0
                    )
                )
            default:
                break
            }
        }

        return events
    }
}

public struct AnthropicProvider: LLMProvider, Sendable {
    public var apiKeyProvider: @Sendable () async throws -> String
    public var baseURL: URL
    public var apiVersion: String
    public var session: URLSession

    public init(
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        baseURL: URL = AnthropicAPI.defaultBaseURL,
        apiVersion: String = AnthropicAPI.anthropicVersion,
        session: URLSession = .newPiDefault
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.baseURL = baseURL
        self.apiVersion = apiVersion
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
                    let apiKey = try await apiKeyProvider()
                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var body: [String: Any] = [
                        "model": model.modelID,
                        "max_tokens": model.maxTokens,
                        "system": systemPrompt,
                        "messages": AnthropicMessageEncoder.encodeMessages(messages),
                        "stream": true,
                    ]

                    if !tools.isEmpty {
                        body["tools"] = AnthropicMessageEncoder.encodeTools(tools)
                    }

                    if model.thinkingLevel != .off {
                        let budget = thinkingBudget(for: model.thinkingLevel)
                        body["thinking"] = [
                            "type": "enabled",
                            "budget_tokens": budget,
                        ]
                        // Anthropic 要求 max_tokens > thinking.budget_tokens，
                        // 相等时请求必 400（例如默认 maxTokens 8192 + high）。
                        body["max_tokens"] = max(model.maxTokens, budget + 1)
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let requestBody = request.httpBody ?? Data()
                    let redactionSecrets = [apiKey]
                    let startedAt = Date()
                    NewPiLogger.logLLMRequest(
                        category: "anthropic",
                        url: baseURL,
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
                            category: "anthropic",
                            statusCode: http.statusCode,
                            elapsedMilliseconds: elapsed,
                            body: message,
                            secrets: redactionSecrets
                        )
                        throw AgentError.llmFailed(message)
                    }

                    if let http = response as? HTTPURLResponse {
                        NewPiLogger.info(
                            category: "anthropic",
                            message: "LLM stream started",
                            details: "HTTP \(http.statusCode)"
                        )
                    }

                    var sseParser = SSEByteStreamParser()
                    var decoder = AnthropicSSEDecoder()
                    var parser = AnthropicStreamParser()

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for block in sseParser.feed(byte) {
                            let parsed = parser.parse(events: decoder.decodeLines(block))
                            for event in parsed {
                                continuation.yield(event)
                            }
                        }
                    }

                    for block in sseParser.finish() {
                        let parsed = parser.parse(events: decoder.decodeLines(block))
                        for event in parsed {
                            continuation.yield(event)
                        }
                    }

                    for event in parser.finish() {
                        continuation.yield(event)
                    }

                    NewPiLogger.logLLMStreamFinished(category: "anthropic", model: model.modelID)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentError.aborted)
                } catch let error as AgentError {
                    NewPiLogger.error(
                        category: "anthropic",
                        message: "LLM request failed",
                        details: error.localizedDescription,
                        secrets: []
                    )
                    continuation.finish(throwing: error)
                } catch {
                    NewPiLogger.error(
                        category: "anthropic",
                        message: "LLM request failed",
                        details: error.localizedDescription
                    )
                    continuation.finish(throwing: AgentError.llmFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func thinkingBudget(for level: ThinkingLevel) -> Int {
        switch level {
        case .off: 0
        case .minimal: 1024
        case .low: 2048
        case .medium: 4096
        case .high: 8192
        }
    }
}

