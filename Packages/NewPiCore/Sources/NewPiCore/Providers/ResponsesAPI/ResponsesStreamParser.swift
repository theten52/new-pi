import Foundation

public struct ResponsesStreamParser: Sendable {
    private struct PendingFunctionCall {
        var callID: String?
        var name: String?
        var arguments: String = ""
    }

    private var pendingCalls: [Int: PendingFunctionCall] = [:]
    private var emittedToolCalls = false

    public init() {}

    public mutating func parse(events: [ResponsesStreamEvent]) -> [LLMStreamEvent] {
        var output: [LLMStreamEvent] = []

        for event in events {
            switch event {
            case let .textDelta(text):
                output.append(.textDelta(text))
            case let .reasoningDelta(text):
                output.append(.thinkingDelta(text))
            case let .functionCallMeta(outputIndex, callID, name):
                var pending = pendingCalls[outputIndex, default: PendingFunctionCall()]
                if let callID { pending.callID = callID }
                if let name { pending.name = name }
                pendingCalls[outputIndex] = pending
            case let .functionCallArgumentsDelta(outputIndex, delta):
                var pending = pendingCalls[outputIndex, default: PendingFunctionCall()]
                pending.arguments += delta
                pendingCalls[outputIndex] = pending
            case let .functionCallArgumentsDone(outputIndex, callID, name, arguments):
                var pending = pendingCalls[outputIndex, default: PendingFunctionCall()]
                if let callID { pending.callID = callID }
                if let name { pending.name = name }
                if !arguments.isEmpty {
                    pending.arguments = arguments
                }
                pendingCalls[outputIndex] = pending
                output.append(contentsOf: flushCall(at: outputIndex))
            case let .completed(status, incompleteReason, inputTokens, outputTokens, cacheReadTokens):
                output.append(contentsOf: flushAllCalls())
                let stopReason = mapStopReason(status: status, incompleteReason: incompleteReason)
                let usage = UsageStats(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens)
                output.append(.completed(stopReason: stopReason, usage: usage))
            case let .failed(message):
                output.append(contentsOf: flushAllCalls())
                // Surface as completed stop so upstream can show error via AgentError path in provider.
                _ = message
            }
        }

        return output
    }

    public mutating func finish() -> [LLMStreamEvent] {
        flushAllCalls()
    }

    private mutating func flushCall(at outputIndex: Int) -> [LLMStreamEvent] {
        guard var pending = pendingCalls.removeValue(forKey: outputIndex),
              let callID = pending.callID,
              let name = pending.name else {
            return []
        }

        emittedToolCalls = true
        let json = pending.arguments.isEmpty ? "{}" : pending.arguments
        let arguments = (try? JSONValueDecoder.decode(from: json)) ?? .object([:])
        return [.toolCall(ToolCallContent(id: callID, name: name, arguments: arguments))]
    }

    private mutating func flushAllCalls() -> [LLMStreamEvent] {
        var output: [LLMStreamEvent] = []
        for index in pendingCalls.keys.sorted() {
            output.append(contentsOf: flushCall(at: index))
        }
        return output
    }

    private func mapStopReason(status: String, incompleteReason: String?) -> StopReason {
        if emittedToolCalls, status == "completed" {
            return .toolUse
        }
        if status == "incomplete", incompleteReason == "max_output_tokens" {
            return .length
        }
        return .stop
    }
}
