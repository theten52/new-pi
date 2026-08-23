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
    public init() {}

    public func parse(events: [AnthropicStreamEvent]) -> [LLMStreamEvent] {
        var output: [LLMStreamEvent] = []
        var toolInputs: [String: String] = [:]
        var toolNames: [String: String] = [:]
        var stopReason: StopReason = .stop
        var usage = UsageStats()

        for event in events {
            switch event {
            case let .textDelta(text):
                output.append(.textDelta(text))
            case let .thinkingDelta(text):
                output.append(.thinkingDelta(text))
            case let .toolInputDelta(id, name, partialJSON):
                toolNames[id] = name
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
            case let .messageDelta(reason, inputTokens, outputTokens):
                stopReason = mapStopReason(reason)
                usage = UsageStats(inputTokens: inputTokens, outputTokens: outputTokens)
            }
        }

        output.append(.completed(stopReason: stopReason, usage: usage))
        return output
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
    case toolInputDelta(id: String, name: String, partialJSON: String)
    case contentBlockStop(id: String, name: String, input: JSONValue?)
    case messageDelta(reason: String?, inputTokens: Int, outputTokens: Int)
}

public struct AnthropicSSEDecoder: Sendable {
    public init() {}

    public func decodeLines(_ lines: [String]) -> [AnthropicStreamEvent] {
        var events: [AnthropicStreamEvent] = []
        var currentEventName: String?
        var openToolBlocks: [Int: (id: String, name: String)] = [:]

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
            case "message_delta":
                let delta = json["delta"] as? [String: Any]
                let usageJSON = json["usage"] as? [String: Any]
                events.append(
                    .messageDelta(
                        reason: delta?["stop_reason"] as? String,
                        inputTokens: usageJSON?["input_tokens"] as? Int ?? 0,
                        outputTokens: usageJSON?["output_tokens"] as? Int ?? 0
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
        session: URLSession = .shared
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
                        body["thinking"] = [
                            "type": "enabled",
                            "budget_tokens": thinkingBudget(for: model.thinkingLevel),
                        ]
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let message = String(data: errorData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                        throw AgentError.llmFailed(message)
                    }

                    var buffer = ""
                    var sseLines: [String] = []
                    let decoder = AnthropicSSEDecoder()
                    let parser = AnthropicStreamParser()

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        let chunk = String(decoding: [byte], as: UTF8.self)
                        buffer += chunk

                        while let newlineIndex = buffer.firstIndex(of: "\n") {
                            var line = String(buffer[..<newlineIndex])
                            buffer = String(buffer[buffer.index(after: newlineIndex)...])
                            if line.hasSuffix("\r") {
                                line.removeLast()
                            }
                            if line.isEmpty {
                                if !sseLines.isEmpty {
                                    let parsed = parser.parse(events: decoder.decodeLines(sseLines))
                                    for event in parsed {
                                        continuation.yield(event)
                                    }
                                    sseLines.removeAll()
                                }
                            } else {
                                sseLines.append(line)
                            }
                        }
                    }

                    if !buffer.isEmpty {
                        sseLines.append(buffer)
                    }
                    if !sseLines.isEmpty {
                        let parsed = parser.parse(events: decoder.decodeLines(sseLines))
                        for event in parsed {
                            continuation.yield(event)
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentError.aborted)
                } catch let error as AgentError {
                    continuation.finish(throwing: error)
                } catch {
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

