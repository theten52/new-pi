import Foundation
import NewPiCore

// 该检查只编译真实 FlowController/RuntimeStore；转录渲染不参与测试，使用空适配器。
struct NewPiTranscriptItem {}
struct ChatRoomTranscriptAdapter {
    func adapt(messages: [ChatRoomMessage], roles: [ChatRoomRole], liveSpeech: ChatRoomLiveSpeech?)
        -> (items: [NewPiTranscriptItem], tintHues: [UUID: Int]) { ([], [:]) }
}

@main
struct ChatRoomControllerChecks {
    @MainActor
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 随机 UUID + 不配置角色：不会请求模型、运行工具或保存对话。
        let room = ChatRoom(name: "controller-check", roles: [], projectPath: dir.path)
        let store = ChatRoomRuntimeStore.shared
        let controller = store.controller(for: room)
        precondition(controller.directoryIssue == nil)

        controller.runtime.isRunning = true
        do {
            try store.delete(room)
            fatalError("running room deletion was allowed")
        } catch { precondition(error.localizedDescription.contains("请先停止")) }
        controller.runtime.isRunning = false

        controller.triggerNextSpeaker()
        precondition(controller.isTaskActive && store.isRunning(chatroomID: room.id))
        controller.cancelRunning()
        precondition(controller.isTaskActive, "cancel must wait for task exit before allowing deletion")
        do {
            try store.delete(room)
            fatalError("cancel-pending room deletion was allowed")
        } catch { precondition(error.localizedDescription.contains("请先停止")) }
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!controller.isBusy)

        let approvalTask = Task {
            await controller.approvalManager.requestApproval(
                toolCall: ToolCallContent(id: UUID().uuidString, name: "write_file", arguments: .object([:])),
                roleID: "test", roleName: "test"
            )
        }
        for _ in 0..<100 where controller.approvalManager.pendingApprovals.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!controller.approvalManager.pendingApprovals.isEmpty)
        do {
            try store.delete(room)
            fatalError("approval-pending room deletion was allowed")
        } catch { precondition(error.localizedDescription.contains("请先停止")) }
        approvalTask.cancel()
        _ = await approvalTask.value
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!controller.isBusy)

        try FileManager.default.removeItem(at: dir)
        controller.triggerNextSpeaker()
        precondition(controller.directoryIssue == .missing && !controller.isTaskActive)
        controller.triggerSpeaker(roleID: "missing-role")
        precondition(controller.directoryIssue == .missing && !controller.isTaskActive)
        precondition(controller.runtime.messages.isEmpty)
        precondition(controller.runtime.currentSpeakerIndex == 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        controller.refreshWorkingDirectory()
        precondition(controller.directoryIssue == nil)
        print("PASS: running/cancel-pending/approval-pending deletion blocked; both speech paths reject missing folders; restored folder recovers")
    }
}
