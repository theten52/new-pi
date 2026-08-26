import Foundation

public enum ResponsesStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
    case functionCallMeta(outputIndex: Int, callID: String?, name: String?)
    case functionCallArgumentsDelta(outputIndex: Int, delta: String)
    case functionCallArgumentsDone(outputIndex: Int, callID: String?, name: String?, arguments: String)
    case completed(status: String, incompleteReason: String?, inputTokens: Int, outputTokens: Int)
    case failed(message: String)
}

public struct ResponsesSSEDecoder: Sendable {
    public init() {}

    public func decodeLines(_ lines: [String]) -> [ResponsesStreamEvent] {
        var events: [ResponsesStreamEvent] = []

        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else {
                continue
            }

            switch type {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    events.append(.textDelta(delta))
                }
            case "response.reasoning_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    events.append(.reasoningDelta(delta))
                }
            case "response.output_item.added":
                if let item = json["item"] as? [String: Any],
                   item["type"] as? String == "function_call" {
                    let outputIndex = json["output_index"] as? Int ?? 0
                    events.append(.functionCallMeta(
                        outputIndex: outputIndex,
                        callID: item["call_id"] as? String,
                        name: item["name"] as? String
                    ))
                }
            case "response.function_call_arguments.delta":
                let outputIndex = json["output_index"] as? Int ?? 0
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    events.append(.functionCallArgumentsDelta(outputIndex: outputIndex, delta: delta))
                }
            case "response.function_call_arguments.done":
                let outputIndex = json["output_index"] as? Int ?? 0
                events.append(.functionCallArgumentsDone(
                    outputIndex: outputIndex,
                    callID: json["call_id"] as? String,
                    name: json["name"] as? String,
                    arguments: json["arguments"] as? String ?? "{}"
                ))
            case "response.completed":
                events.append(parseTerminalEvent(json, defaultStatus: "completed"))
            case "response.incomplete":
                events.append(parseTerminalEvent(json, defaultStatus: "incomplete"))
            case "response.failed":
                let response = json["response"] as? [String: Any]
                let error = response?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "Responses API request failed."
                events.append(.failed(message: message))
            default:
                continue
            }
        }

        return events
    }

    private func parseTerminalEvent(_ json: [String: Any], defaultStatus: String) -> ResponsesStreamEvent {
        let response = json["response"] as? [String: Any] ?? [:]
        let status = response["status"] as? String ?? defaultStatus
        let incompleteDetails = response["incomplete_details"] as? [String: Any]
        let incompleteReason = incompleteDetails?["reason"] as? String
        let usage = response["usage"] as? [String: Any] ?? [:]
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        return .completed(
            status: status,
            incompleteReason: incompleteReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }
}
