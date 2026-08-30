import Foundation

public enum ResponsesMessageEncoder {
    public static func encodeInput(_ messages: [AgentMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []

        for message in messages {
            switch message {
            case let .user(user):
                items.append(userMessageItem(user))
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

    /// 用户消息：无附件时复用 `input_text`；有附件时 content 升级为
    /// `[{type:"input_text"},{type:"input_image",image_url:"data:…"}]`。
    private static func userMessageItem(_ user: UserMessage) -> [String: Any] {
        guard !user.attachments.isEmpty else {
            return messageItem(role: "user", text: user.content, contentType: "input_text")
        }
        var content: [[String: Any]] = []
        if !user.content.isEmpty {
            content.append(["type": "input_text", "text": user.content])
        }
        for attachment in user.attachments {
            guard let data = SessionAttachments.data(for: attachment) else { continue }
            let dataURL = "data:\(attachment.mediaType);base64,\(data.base64EncodedString())"
            content.append(["type": "input_image", "image_url": dataURL])
            // 缩放/坐标映射说明（BACKLOG-IMAGE-INPUT）：紧跟 input_image 块以 input_text 块下发。
            if let note = attachment.note, !note.isEmpty {
                content.append(["type": "input_text", "text": note])
            }
        }
        return ["type": "message", "role": "user", "content": content]
    }
}
