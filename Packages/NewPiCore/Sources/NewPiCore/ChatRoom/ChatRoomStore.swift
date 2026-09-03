import Foundation

/// 聊天室存储管理
public final class ChatRoomStore: Sendable {
    public static let shared = ChatRoomStore()
    
    private let baseDirectory: URL
    
    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? NewPiConfig.defaultAgentDirectory.appendingPathComponent("chatrooms")
    }
    
    // MARK: - 目录操作
    
    private func chatroomDirectory(for id: String) -> URL {
        baseDirectory.appendingPathComponent(id)
    }
    
    private func chatroomConfigURL(for id: String) -> URL {
        chatroomDirectory(for: id).appendingPathComponent("chatroom.json")
    }
    
    private func messagesURL(for id: String) -> URL {
        chatroomDirectory(for: id).appendingPathComponent("messages.jsonl")
    }
    
    private func ensureDirectoryExists(for id: String) throws {
        let dir = chatroomDirectory(for: id)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - ChatRoom CRUD
    
    /// 保存聊天室配置
    public func save(_ chatroom: ChatRoom) throws {
        try ensureDirectoryExists(for: chatroom.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chatroom)
        try data.write(to: chatroomConfigURL(for: chatroom.id), options: .atomic)
    }
    
    /// 加载聊天室配置
    public func load(id: String) throws -> ChatRoom {
        let url = chatroomConfigURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ChatRoomError.notFound(id)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatRoom.self, from: data)
    }
    
    /// 删除聊天室
    public func delete(id: String) throws {
        let dir = chatroomDirectory(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
    
    /// 列出所有聊天室
    public func listAll() throws -> [ChatRoom] {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else {
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var chatrooms: [ChatRoom] = []
        for dir in contents {
            let configURL = dir.appendingPathComponent("chatroom.json")
            if FileManager.default.fileExists(atPath: configURL.path) {
                do {
                    let chatroom = try load(id: dir.lastPathComponent)
                    chatrooms.append(chatroom)
                } catch {
                    // 跳过损坏的配置
                    continue
                }
            }
        }
        return chatrooms.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    // MARK: - 消息操作
    
    /// 追加消息
    public func appendMessage(_ message: ChatRoomMessage, to chatroomID: String) throws {
        try ensureDirectoryExists(for: chatroomID)
        let url = messagesURL(for: chatroomID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(message)
        data.append("\n".data(using: .utf8)!)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
    
    /// 加载所有消息
    public func loadMessages(for chatroomID: String) throws -> [ChatRoomMessage] {
        let url = messagesURL(for: chatroomID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var messages: [ChatRoomMessage] = []
        var currentIndex = data.startIndex
        while currentIndex < data.endIndex {
            // 找到下一个换行符
            if let newlineIndex = data[currentIndex...].firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = data[currentIndex..<newlineIndex]
                if !lineData.isEmpty {
                    if let message = try? decoder.decode(ChatRoomMessage.self, from: Data(lineData)) {
                        messages.append(message)
                    }
                }
                currentIndex = newlineIndex + 1
            } else {
                // 最后一行没有换行符
                let lineData = data[currentIndex...]
                if !lineData.isEmpty {
                    if let message = try? decoder.decode(ChatRoomMessage.self, from: Data(lineData)) {
                        messages.append(message)
                    }
                }
                break
            }
        }
        return messages
    }
    
    /// 清空消息
    public func clearMessages(for chatroomID: String) throws {
        let url = messagesURL(for: chatroomID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 错误类型

public enum ChatRoomError: Error, LocalizedError {
    case notFound(String)
    case invalidPhase(ChatRoomPhase)
    case roundLimitReached
    case noSelectedOption
    case roleNotConfigured(String)
    
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            "聊天室不存在: \(id)"
        case .invalidPhase(let phase):
            "无效的阶段: \(phase)"
        case .roundLimitReached:
            "已达到最大轮数限制（3轮）"
        case .noSelectedOption:
            "未选择方案"
        case .roleNotConfigured(let roleID):
            "角色未配置模型: \(roleID)"
        }
    }
}
