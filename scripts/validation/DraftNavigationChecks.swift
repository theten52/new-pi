import AppKit
import Combine
import NewPiCore
import SwiftUI

// 仅替换不在本检查范围的渲染和发送后端。草稿归属、视图声明/绑定及 NSTextView 来自生产源码。
@MainActor final class TranscriptDocumentController: ObservableObject {
    static var scrollRequests = 0
    func scrollToBottom() { Self.scrollRequests += 1 }
}
@MainActor final class NewPiViewModel: ObservableObject {
    var acceptsSend = false
    var accepted = 0
    func send(_ text: String, draftAttachments: [DraftImageAttachment]) -> Bool {
        if acceptsSend { accepted += 1 }
        return acceptsSend
    }
}
struct ChatRoomTranscriptAdapter {
    func adapt(messages: [ChatRoomMessage], roles: [ChatRoomRole], liveSpeech: ChatRoomLiveSpeech?)
        -> (items: [NewPiTranscriptItem], tintHues: [UUID: Int]) { ([], [:]) }
}
struct NeverProvider: LLMProvider {
    func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage], tools: [ToolDefinition])
        -> AsyncThrowingStream<LLMStreamEvent, Error> { fatalError("本检查不得调用模型") }
}
@MainActor enum ProbeBindings {
    static var text: Binding<String>?
    static var attachments: Binding<[DraftImageAttachment]>?
}
@MainActor final class Selection: ObservableObject { @Published var index = 0 }
@MainActor final class ParentNotifications { var count = 0 }
private struct DraftRoot: View {
    @ObservedObject var selection: Selection
    let sessions: [SessionRuntime]
    let rooms: [ChatRoomFlowController]
    let viewModel: NewPiViewModel
    var body: some View {
        if selection.index < 2 {
            SessionDraftFixture(runtime: sessions[selection.index], viewModel: viewModel)
                .id(sessions[selection.index].sessionID)
        } else {
            RoomDraftFixture(viewModel: viewModel, controller: rooms[selection.index - 2])
                .id(rooms[selection.index - 2].runtime.chatroom.id)
        }
    }
}

@main @MainActor struct DraftNavigationChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        print("PASS: \(message)")
    }
    static func findEditor(_ root: NSView) -> NewPiComposerInnerTextView? {
        if let editor = root as? NewPiComposerInnerTextView { return editor }
        return root.subviews.lazy.compactMap(findEditor).first
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("FAIL: draft navigation timeout"); exit(1) }
        NSApp.run()
    }
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = (0..<2).map { _ in
            SessionRuntime(session: AgentSessionFactory.codingSession(workingDirectory: directory,
                llm: NeverProvider(), model: ModelConfig(provider: "fixture", modelID: "never")),
                fileURL: directory.appendingPathComponent(UUID().uuidString), sessionID: UUID())
        }
        let disk = ChatRoomStore(baseDirectory: directory.appendingPathComponent("rooms"))
        let store = ChatRoomRuntimeStore(store: disk)
        let rooms = (0..<2).map { store.controller(for: ChatRoom(name: "fixture-\($0)", roles: [], projectPath: directory.path)) }
        let notifications = ParentNotifications()
        let subscriptions = sessions.map { $0.objectWillChange.sink { notifications.count += 1 } }
            + rooms.map { $0.objectWillChange.sink { notifications.count += 1 } }
            + [store.objectWillChange.sink { notifications.count += 1 }]
        defer { subscriptions.forEach { $0.cancel() } }
        let viewModel = NewPiViewModel()
        let selection = Selection()
        let host = NSHostingView(rootView: DraftRoot(selection: selection, sessions: sessions, rooms: rooms, viewModel: viewModel))
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 600, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await settle()
        func editor() throws -> NewPiComposerInnerTextView {
            guard let editor = findEditor(host) else { throw Failure(message: "未找到生产输入框") }
            return editor
        }
        func select(_ index: Int) async throws {
            let old = try editor()
            ProbeBindings.text = nil
            ProbeBindings.attachments = nil
            selection.index = index
            try await settle()
            try require(try editor() !== old && ProbeBindings.text != nil, "切到 \(index)：输入视图确实重建，不是透明度切换")
        }
        func type(_ text: String) async throws {
            let editor = try editor()
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(text, replacementRange: editor.selectedRange())
            try await settle()
            try require(editor.string == text && ProbeBindings.text?.wrappedValue == text, "真实 NSTextView → 生产 Binding 同步")
        }
        let image = DraftImageAttachment(data: Data([1, 2, 3]), displayName: "fixture.png", mediaType: "image/png")
        try await type("Session A 草稿")
        ProbeBindings.attachments?.wrappedValue = [image]
        try await select(2)
        try await type("Room A 草稿")
        try await select(3)
        try await type("Room B 草稿")
        try await select(2)
        try require(try editor().string == "Room A 草稿", "Room A→B→A 草稿隔离且保留")
        try await select(0)
        try require(try editor().string == "Session A 草稿" && ProbeBindings.attachments?.wrappedValue == [image],
                    "Session→Room→Session 文本和图片草稿保留")
        try await select(1)
        try require(try editor().string.isEmpty && ProbeBindings.attachments?.wrappedValue.isEmpty == true, "新 Session 不串入旧文本或图片")
        try await type("Session B 草稿")
        try await select(0)
        try require(try editor().string == "Session A 草稿", "Session A→B→A 强制重建后保留")
        try require(notifications.count == 0, "逐键/附件草稿变化不广播到 SessionRuntime、聊天室控制器或根列表")
        let input = try editor()
        input.onSubmit?() // 使用提取的生产 sendComposerInput；发送后端只返回接受/拒绝。
        try await settle()
        try require(input.string == "Session A 草稿" && ProbeBindings.attachments?.wrappedValue == [image], "发送拒绝不清草稿")
        viewModel.acceptsSend = true
        sessions[0].isStreaming = true
        input.onSubmit?()
        try require(viewModel.accepted == 0, "运行中不能发送或清空草稿")
        sessions[0].isStreaming = false
        input.onSubmit?()
        try await settle()
        try require(input.string.isEmpty && ProbeBindings.attachments?.wrappedValue.isEmpty == true && viewModel.accepted == 1,
                    "成功接受后只清当前 Session 草稿")
        try await select(1)
        try require(try editor().string == "Session B 草稿", "清 A 不影响 B")
        try await select(2)
        try require(try editor().string == "Room A 草稿", "Room→Session→Room 草稿保留")
        // 调用真实聊天室提交方法 + 控制器 + Core 存储，故障只发生在随机临时路径。
        let room = rooms[0]
        let blocked = directory.appendingPathComponent("rooms").appendingPathComponent(room.runtime.chatroom.id)
            .appendingPathComponent("messages.jsonl")
        for running in [false, true] {
            let prior = room.runtime.messages.map(\.id)
            let oldScrolls = TranscriptDocumentController.scrollRequests
            room.runtime.isRunning = running
            try await type("  发送失败后重试 \(running)  \n")
            let originalDraft = try editor().string
            // 临时历史仍在 runtime 中；故障解除后恢复到测试磁盘。避免 chmod 的权限差异。
            if FileManager.default.fileExists(atPath: blocked.path) { try FileManager.default.removeItem(at: blocked) }
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try editor().onSubmit?()
            try await settle()
            try require(room.flowError != nil, "聊天室磁盘错误向 UI 报告")
            try require(try editor().string == originalDraft, "聊天室发送失败保留原始草稿（含空白）")
            try require(room.runtime.messages.map(\.id) == prior, "失败不产生仅存在内存的消息")
            try require(TranscriptDocumentController.scrollRequests == oldScrolls, "失败不发起落底意图")
            room.flowError = nil // 等价于用户关闭错误提示。
            try FileManager.default.removeItem(at: blocked)
            try disk.saveMessages(room.runtime.messages, for: room.runtime.chatroom.id)
            try editor().onSubmit?()
            try await settle()
            try require(try editor().string.isEmpty && room.runtime.messages.count == prior.count + 1,
                        "聊天室恢复后重试接受一次并清稿（running=\(running)）")
            try require(try disk.loadMessages(for: room.runtime.chatroom.id).map(\.id) == room.runtime.messages.map(\.id),
                        "重试后内存与磁盘消息 ID 一致，无重复")
            try require(TranscriptDocumentController.scrollRequests == oldScrolls + 1, "成功后才发起一次落底")
            try editor().onSubmit?()
            try await settle()
            try require(room.runtime.messages.count == prior.count + 1
                        && TranscriptDocumentController.scrollRequests == oldScrolls + 1,
                        "清稿后再次提交不重复发送或落底")
        }
        room.runtime.isRunning = false
        print("PASS: 生产草稿声明/绑定 + 实际 SessionRuntime/聊天室控制器 + 真实输入框重建；无网络、无用户数据")
    }
}