import Foundation

public enum ResponsesMessageEncoder {
    public static func encodeInput(_ messages: [AgentMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []

        for message in messages {
            switch message {
            case let .user(user):
                items.append(messageItem(role: "user", text: user.content, contentType: "input_text"))
            case let .assistant(assistant):
                if !assistant.reasoningContent.isEmpty {
                    items.append([
                        "type": "reasoning",
                        "summary": [
                            [
                                "type": "reasoning_text",
                                "text": assistant.reasoningContent,
                            ],
                        ],
                    ])
                }
                if !assistant.text.isEmpty {
                    items.append(messageItem(role: "assistant", text: assistant.text, contentType: "output_text"))
                }
                for call in assistant.toolCalls {
                    let arguments = (try? String(data: call.arguments.toJSONData(), encoding: .utf8)) ?? "{}"
                    items.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": arguments,
                    ])
                }
            case let .toolResult(toolResult):
                items.append([
                    "type": "function_call_output",
                    "call_id": toolResult.toolCallID,
                    "output": toolResult.content,
                ])
            case let .compactionSummary(summary):
                items.append(messageItem(
                    role: "user",
                    text: "Conversation summary:\n\(summary)",
                    contentType: "input_text"
                ))
            }
        }

        return items
    }

    public static func encodeTools(_ tools: [ToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": (try? tool.parameters.toJSONObject()) ?? [
                    "type": "object",
                    "properties": [:],
                ],
            ] as [String: Any]
        }
    }

    private static func messageItem(role: String, text: String, contentType: String) -> [String: Any] {
        [
            "type": "message",
            "role": role,
            "content": [
                [
                    "type": contentType,
                    "text": text,
                ],
            ],
        ]
    }
}
