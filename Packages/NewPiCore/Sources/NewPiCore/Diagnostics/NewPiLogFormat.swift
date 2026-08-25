import Foundation

public enum NewPiLogFormat {
    public static func describeJSONValue(_ value: JSONValue, maxLength: Int = 2000) -> String {
        let text: String
        if let data = try? value.toJSONData(),
           let pretty = String(data: data, encoding: .utf8) {
            text = pretty
        } else {
            text = String(describing: value)
        }
        return truncate(text, maxLength: maxLength)
    }

    public static func describeToolCall(_ call: ToolCallContent) -> String {
        """
        id=\(call.id)
        name=\(call.name)
        arguments=\(describeJSONValue(call.arguments))
        """
    }

    public static func describeToolRegistry(_ tools: [any AgentTool]) -> String {
        tools.map(\.name).sorted().joined(separator: ", ")
    }

    public static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let index = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<index]) + "…(\(text.count) chars total)"
    }
}
