import Foundation

/// 聊天室模板（设计文档「聊天室模板」章节，决策 #20~24）
///
/// 一套可复用的角色配置：创建聊天室时选择模板一键填充角色区（值拷贝，
/// 模板是起点，套用后仍可临时调整），模板本身可增删改。
public struct ChatRoomTemplate: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var roles: [ChatRoomRole]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        roles: [ChatRoomRole] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.roles = roles
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension ChatRoomTemplate {
    /// 套用模板（决策 #20）：绑定失效的角色整体降级为未配置，避免创建出的
    /// 聊天室到发言时才报错。两种失效：
    /// - provider 已删除（profileID 不在 `profileModels` 中）
    /// - model 已从 provider 的模型列表移除（modelID 不在对应列表中）
    /// provider 有效但未绑 model 的角色保留原样（等用户补选）。
    /// 返回降级后的角色副本与失效角色 ID 列表（供 UI 按角色定位提示）。
    func resolvedRoles(profileModels: [String: [String]]) -> (roles: [ChatRoomRole], invalidatedRoleIDs: [String]) {
        var invalidatedRoleIDs: [String] = []
        let resolved = roles.map { role -> ChatRoomRole in
            var role = role
            let isInvalid: Bool
            if let profileID = role.providerProfileID {
                if let models = profileModels[profileID] {
                    isInvalid = role.modelID.map { !models.contains($0) } ?? false
                } else {
                    isInvalid = true
                }
            } else {
                isInvalid = false
            }
            if isInvalid {
                invalidatedRoleIDs.append(role.id)
                role.providerProfileID = nil
                role.modelID = nil
            }
            return role
        }
        return (resolved, invalidatedRoleIDs)
    }
}

/// 模板存储：`~/.new-pi/agent/chatroom-templates/{id}.json`
public final class ChatRoomTemplateStore: Sendable {
    public static let shared = ChatRoomTemplateStore()

    private let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
            ?? NewPiConfig.defaultAgentDirectory.appendingPathComponent("chatroom-templates")
    }

    /// 测试用：暴露存储目录（清理临时目录）
    var baseDirectoryForTesting: URL { baseDirectory }

    // MARK: - CRUD

    public func save(_ template: ChatRoomTemplate) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(template)
        try data.write(to: templateURL(for: template.id), options: .atomic)
    }

    public func delete(id: String) throws {
        let url = templateURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 列出所有模板（按 updatedAt 倒序）。首次调用时 seed 内置模板：
    /// 仅当存储目录尚不存在时写入，之后目录存在（哪怕被用户删空）也不再 seed。
    public func listAll() throws -> [ChatRoomTemplate] {
        try seedIfFirstRun()
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else {
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )
        var templates: [ChatRoomTemplate] = []
        for url in contents where url.pathExtension == "json" {
            do {
                templates.append(try decode(from: url))
            } catch {
                // 跳过损坏的模板文件
                continue
            }
        }
        return templates.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 内置模板（决策 #21）

    /// 内置模板。写入顺序即 seed 顺序：默认四人组最后写入（updatedAt 最新，
    /// 在按时间倒序的列表里排最前，作为默认选中项）。
    /// 模板角色不预绑 provider/model——等价原预设流程，用户在模板里绑定一次后复用。
    static func builtinTemplates() -> [ChatRoomTemplate] {
        [
            ChatRoomTemplate(
                name: "两人极速组",
                description: "架构师出方案、程序员直接实现，适合小改动",
                roles: [
                    .from(preset: .architect),
                    .from(preset: .programmer),
                ]
            ),
            ChatRoomTemplate(
                name: "评审组",
                description: "程序员实现、测试员把关，聚焦代码质量",
                roles: [
                    .from(preset: .programmer),
                    .from(preset: .tester),
                ]
            ),
            ChatRoomTemplate(
                name: "默认四人组",
                description: "架构师/程序员/测试员/产品经理，完整协作流程",
                roles: PresetRoleType.allCases.map { .from(preset: $0) }
            ),
        ]
    }

    private func seedIfFirstRun() throws {
        guard !FileManager.default.fileExists(atPath: baseDirectory.path) else { return }
        for template in Self.builtinTemplates() {
            try save(template)
        }
    }

    // MARK: - 私有

    private func templateURL(for id: String) -> URL {
        baseDirectory.appendingPathComponent("\(id).json")
    }

    private func decode(from url: URL) throws -> ChatRoomTemplate {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatRoomTemplate.self, from: data)
    }
}
