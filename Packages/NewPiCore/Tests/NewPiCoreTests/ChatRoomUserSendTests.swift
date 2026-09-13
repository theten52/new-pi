import Foundation
import Testing
@testable import NewPiCore

@Suite("聊天室用户消息接受边界")
@MainActor
struct ChatRoomUserSendTests {
    @Test("写入失败不污染内存，恢复后重试不重复", arguments: [false, true])
    func failedAppendPreservesHistory(running: Bool) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ChatRoomStore(baseDirectory: base)
        let room = ChatRoom(name: "fixture", roles: [], projectPath: base.path)
        try store.save(room)
        let runtime = ChatRoomRuntime(chatroom: room)
        let loop = ChatRoomLoop(store: store)
        try loop.userSpeak(content: "原有消息", runtime: runtime)
        let prior = runtime.messages.map(\.id)
        let updatedAt = runtime.chatroom.updatedAt
        runtime.isRunning = running
        let messages = base.appendingPathComponent(room.id).appendingPathComponent("messages.jsonl")
        let backup = base.appendingPathComponent("saved.jsonl")
        try FileManager.default.moveItem(at: messages, to: backup)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try loop.userSpeak(content: "重试消息", runtime: runtime) }
        #expect(runtime.messages.map(\.id) == prior)
        #expect(runtime.chatroom.updatedAt == updatedAt)
        #expect(runtime.isRunning == running)
        try FileManager.default.removeItem(at: messages)
        try FileManager.default.moveItem(at: backup, to: messages)
        try loop.userSpeak(content: "重试消息", runtime: runtime)
        #expect(runtime.messages.count == 2)
        #expect(try store.loadMessages(for: room.id).map(\.id) == runtime.messages.map(\.id))
    }

    @Test("排序元数据失败不拒绝已经保存的消息")
    func metadataFailureDoesNotRejectMessage() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ChatRoomStore(baseDirectory: base)
        let room = ChatRoom(name: "fixture", roles: [], projectPath: base.path)
        let runtime = ChatRoomRuntime(chatroom: room)
        // 配置路径为目录，消息路径仍可写；无模型、无权限修改。
        try FileManager.default.createDirectory(at: base.appendingPathComponent(room.id).appendingPathComponent("chatroom.json"), withIntermediateDirectories: true)
        try ChatRoomLoop(store: store).userSpeak(content: "已接受", runtime: runtime)
        #expect(runtime.messages.count == 1)
        #expect(try store.loadMessages(for: room.id).map(\.id) == runtime.messages.map(\.id))
    }
}