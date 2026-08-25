import Foundation

/// Repairs conversation history before sending to LLM providers.
public enum AgentMessageHistoryRepair {
    /// Inserts error tool results for assistant tool calls that were never executed.
    public static func repairOrphanedToolCalls(in messages: inout [AgentMessage]) {
        var index = 0
        while index < messages.count {
            guard case let .assistant(assistant) = messages[index],
                  !assistant.toolCalls.isEmpty else {
                index += 1
                continue
            }

            let expectedIDs = assistant.toolCalls.map(\.id)
            var foundIDs = Set<String>()
            var scan = index + 1
            while scan < messages.count {
                if case let .toolResult(result) = messages[scan] {
                    foundIDs.insert(result.toolCallID)
                    scan += 1
                    continue
                }
                break
            }

            let missing = expectedIDs.filter { !foundIDs.contains($0) }
            guard !missing.isEmpty else {
                index = scan
                continue
            }

            NewPiLogger.error(
                category: "agent-loop",
                message: "Repairing orphaned tool calls in message history",
                details: """
                missing=\(missing.joined(separator: ", "))
                assistantTools=\(assistant.toolCalls.map(\.name).joined(separator: ", "))
                """
            )

            let repairs: [AgentMessage] = assistant.toolCalls
                .filter { missing.contains($0.id) }
                .map { call in
                    .toolResult(
                        ToolResultMessage(
                            toolCallID: call.id,
                            toolName: call.name,
                            content: "Tool call was not executed (recovered from incomplete session state).",
                            isError: true
                        )
                    )
                }

            messages.insert(contentsOf: repairs, at: scan)
            index = scan + repairs.count
        }
    }
}
