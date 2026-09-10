import Combine
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
    private final class Observations {
        var storeChanges = 0
        var detailChanges = 0
        var busyStates: [Bool] = []
    }

    @MainActor
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 随机 UUID + 临时存储 + 不配置角色：不请求模型、不运行工具、不修改用户数据。
        let room = ChatRoom(name: "controller-check", roles: [], projectPath: dir.path)
        let disk = ChatRoomStore(baseDirectory: dir.appendingPathComponent("store"))
        try disk.save(room)
        let store = ChatRoomRuntimeStore(store: disk)
        let controller = store.controller(for: room)
        precondition(controller.directoryIssue == nil)
        let observations = Observations()
        let rootSubscription = store.objectWillChange.sink { observations.storeChanges += 1 }
        let detailSubscription = controller.objectWillChange.sink { observations.detailChanges += 1 }
        let busySubscription = controller.busyChanges.sink { observations.busyStates.append($0) }
        defer { rootSubscription.cancel(); detailSubscription.cancel(); busySubscription.cancel() }

        // 详情仍然接收正文等更新；Store 不因这些无关字段重复失效。
        controller.runtime.messages = [ChatRoomMessage(chatroomID: room.id, roleID: "agent", content: "", phase: .discussion)]
        for _ in 0..<100 { controller.runtime.messages[0].content += "token" }
        controller.runtime.liveSpeech = ChatRoomLiveSpeech(id: "speech", phase: .thinking)
        controller.runtime.usage = UsageStats()
        controller.runtime.currentSpeakerIndex = 0
        controller.flowError = "detail-only error"
        precondition(observations.storeChanges == 0)
        precondition(observations.detailChanges >= 105)
        controller.runtime.messages = []
        controller.runtime.liveSpeech = nil
        controller.flowError = nil

        // 元数据仍同步到列表（阶段徽章、名称、排序信息都不能丢）。
        controller.runtime.chatroom.currentPhase = .execution
        precondition(store.chatrooms.first?.currentPhase == .execution)
        controller.runtime.chatroom.name = "renamed"
        controller.runtime.chatroom.updatedAt = Date(timeIntervalSince1970: 1)
        precondition(store.chatrooms.first?.name == "renamed")
        precondition(store.chatrooms.first?.updatedAt == Date(timeIntervalSince1970: 1))
        precondition(observations.storeChanges == 3)
        controller.runtime.chatroom.currentPhase = .discussion
        observations.storeChanges = 0

        controller.runtime.isRunning = true
        precondition(observations.storeChanges == 1)
        controller.runtime.isRunning = true
        precondition(observations.storeChanges == 1, "Same busy value must not invalidate store")
        do {
            try store.delete(room)
            fatalError("running room deletion was allowed")
        } catch { precondition(error.localizedDescription.contains("请先停止")) }
        controller.runtime.isRunning = false
        precondition(observations.storeChanges == 2)
        precondition(observations.busyStates == [false, true, false])

        let beforeTask = observations.storeChanges
        controller.triggerNextSpeaker()
        precondition(controller.isTaskActive && store.isRunning(chatroomID: room.id))
        precondition(observations.storeChanges == beforeTask + 1, "Task creation must notify before runtime begins")
        controller.cancelRunning()
        precondition(controller.isTaskActive, "cancel must wait for task exit before allowing deletion")
        do {
            try store.delete(room)
            fatalError("cancel-pending room deletion was allowed")
        } catch { precondition(error.localizedDescription.contains("请先停止")) }
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!controller.isBusy)
        precondition(observations.storeChanges == beforeTask + 2, "Cancelled task exit must unlock the sidebar")

        let beforeApproval = observations.storeChanges
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
        precondition(observations.storeChanges == beforeApproval + 1)
        do {
            try store.delete(room)
            fatalError("approval-pending room deletion was allowed")
        } catch { precondition(error.localizedDescription.contains("请先停止")) }
        approvalTask.cancel()
        _ = await approvalTask.value
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!controller.isBusy)
        precondition(observations.storeChanges == beforeApproval + 2)

        // 多个忙碌原因重叠时，只有整体 false/true 翻转通知列表。
        let beforeOverlap = observations.storeChanges
        controller.runtime.isRunning = true
        let overlappingApproval = Task {
            await controller.approvalManager.requestApproval(
                toolCall: ToolCallContent(id: UUID().uuidString, name: "write_file", arguments: .object([:])),
                roleID: "test", roleName: "test")
        }
        for _ in 0..<100 where controller.approvalManager.pendingApprovals.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!controller.approvalManager.pendingApprovals.isEmpty)
        controller.runtime.isRunning = false
        precondition(store.isRunning(chatroomID: room.id))
        precondition(observations.storeChanges == beforeOverlap + 1)
        overlappingApproval.cancel()
        _ = await overlappingApproval.value
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!controller.isBusy && observations.storeChanges == beforeOverlap + 2)

        // 后台聊天室正文同样不能触发根列表刷新，但忙碌边界必须通知。
        let background = ChatRoom(name: "background", projectPath: dir.path)
        let backgroundController = store.controller(for: background)
        let beforeBackground = observations.storeChanges
        backgroundController.runtime.messages.append(ChatRoomMessage(chatroomID: background.id, roleID: "agent", content: "background text", phase: .discussion))
        precondition(observations.storeChanges == beforeBackground)
        backgroundController.runtime.isRunning = true
        precondition(observations.storeChanges == beforeBackground + 1)
        backgroundController.runtime.isRunning = false

        try FileManager.default.removeItem(at: dir)
        controller.triggerNextSpeaker()
        precondition(controller.directoryIssue == .missing && !controller.isTaskActive)
        precondition(store.directoryIssues[room.id] == .missing, "Directory errors must still reach sidebar")
        controller.triggerSpeaker(roleID: "missing-role")
        precondition(controller.directoryIssue == .missing && !controller.isTaskActive)
        precondition(controller.runtime.messages.isEmpty)
        precondition(controller.runtime.currentSpeakerIndex == 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        controller.refreshWorkingDirectory()
        precondition(controller.directoryIssue == nil)
        precondition(store.directoryIssues[room.id] == nil)
        store.refreshWorkingDirectories()
        let beforeRefresh = observations.storeChanges
        store.refreshWorkingDirectories()
        precondition(observations.storeChanges == beforeRefresh, "Unchanged directory health must not notify")

        // 移除控制器订阅后，外部保留的旧控制器不能继续使列表失效。
        try store.delete(room)
        let afterDelete = observations.storeChanges
        controller.runtime.isRunning = true
        controller.runtime.chatroom.name = "stale-controller"
        precondition(observations.storeChanges == afterDelete)
        print("PASS: text/background isolation; metadata/directory propagation; busy overlap/deduplication; deletion/approval/cancel guards; subscription cleanup")
    }
}
