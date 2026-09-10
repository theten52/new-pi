import Combine
import Foundation
import NewPiCore

@MainActor
private final class Counter {
    var value = 0
}

@main
struct ChatRoomPerformanceChecks {
    @MainActor
    static func main() throws {
        let store = ChatRoomRuntimeStore.shared
        let room = ChatRoom(name: "performance-fixture", projectPath: FileManager.default.temporaryDirectory.path)
        let controller = store.controller(for: room)
        let role = ChatRoomRole(name: "Mock", description: "", systemPrompt: "")
        let rootChanges = Counter(), detailChanges = Counter()
        let rootSubscription = store.objectWillChange.sink { rootChanges.value += 1 }
        let detailSubscription = controller.objectWillChange.sink { detailChanges.value += 1 }
        defer { rootSubscription.cancel(); detailSubscription.cancel() }

        print("case,messages,items,updates,storeNotifications,detailNotifications,adaptP50ms,adaptP95ms,signatureP50ms,signatureP95ms,changedItems")
        for (name, count, tools) in [("short", 20, false), ("long", 500, false), ("tools", 200, true)] {
            var history: [ChatRoomMessage] = []
            for index in 0..<count {
                let id = UUID().uuidString
                history.append(ChatRoomMessage(id: id, chatroomID: room.id, roleID: role.id,
                    content: String(repeating: "History \(index) text. ", count: 80),
                    reasoningContent: tools ? String(repeating: "Reasoning. ", count: 100) : nil,
                    speechID: id, phase: .discussion,
                    toolCalls: tools ? [ChatRoomToolCall(id: "tool-\(index)", name: "read", arguments: "{\"path\":\"file.swift\"}")] : nil,
                    toolResults: tools ? [ChatRoomToolResult(toolCallID: "tool-\(index)", output: String(repeating: "Tool output\n", count: 100))] : nil))
            }
            let liveID = UUID().uuidString
            history.append(ChatRoomMessage(id: liveID, chatroomID: room.id, roleID: role.id,
                content: "Streaming", speechID: liveID, phase: .discussion))
            controller.runtime.chatroom.roles = [role]
            controller.runtime.messages = history
            controller.runtime.isRunning = true
            controller.runtime.liveSpeech = ChatRoomLiveSpeech(id: liveID, messageID: liveID, phase: .text)
            let warm = controller.transcriptSnapshot()
            var signatures: [UUID: String] = [:]
            for item in warm.items {
                signatures[item.id] = signature(item, lastID: warm.items.last?.id, tint: warm.tintHues[item.id])
            }
            rootChanges.value = 0
            detailChanges.value = 0
            var adaptTimes: [Double] = [], diffTimes: [Double] = []
            var changed = 0
            for _ in 0..<100 {
                controller.runtime.messages[count].content += " delta"
                let start = ContinuousClock.now
                let snapshot = controller.transcriptSnapshot()
                let adapted = ContinuousClock.now
                var next: [UUID: String] = [:]
                for item in snapshot.items {
                    let value = signature(item, lastID: snapshot.items.last?.id, tint: snapshot.tintHues[item.id])
                    if signatures[item.id] != value { changed += 1 }
                    next[item.id] = value
                }
                signatures = next
                adaptTimes.append(milliseconds(start.duration(to: adapted)))
                diffTimes.append(milliseconds(adapted.duration(to: .now)))
            }
            precondition(changed == 100, "Only the active message should change")
            if ProcessInfo.processInfo.environment["NEWPI_EXPECT_FILTERED_NOTIFICATIONS"] == "1" {
                precondition(rootChanges.value == 0, "Text deltas must not invalidate the sidebar store")
                precondition(detailChanges.value == 100, "Detail must continue to receive every update")
            }
            let values = [percentile(adaptTimes, 0.5), percentile(adaptTimes, 0.95),
                          percentile(diffTimes, 0.5), percentile(diffTimes, 0.95)]
                .map { String(format: "%.3f", $0) }.joined(separator: ",")
            print("\(name),\(history.count),\(warm.items.count),100,\(rootChanges.value),\(detailChanges.value),\(values),\(changed)")
            controller.runtime.isRunning = false
            controller.runtime.liveSpeech = nil
        }
    }

    private static func signature(_ item: NewPiTranscriptItem, lastID: UUID?, tint: Int?) -> String {
        TranscriptSignatureProbe.signature(of: item,
            streaming: item.isStreaming(isRunning: true, bubbleComplete: false, lastItemID: lastID), tint: tint)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        values.sorted()[Int(Double(values.count - 1) * fraction)]
    }
}
