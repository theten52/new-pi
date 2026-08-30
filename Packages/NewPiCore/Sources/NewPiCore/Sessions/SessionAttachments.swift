import Foundation

/// 会话图片附件的受控存储与读取（BACKLOG-IMAGE-INPUT）。
///
/// 附件以**本地文件路径引用**持久化（`MessageAttachment.path` 存相对附件根目录的路径），
/// provider 序列化时从这里读取文件字节并 base64 注入。路径解析强制限定在附件根目录内，
/// 杜绝路径穿越（`../`）读取宿主文件——渲染层与序列化层共用同一受控边界。
///
/// 附件目录结构：`~/.new-pi/agent/sessions/attachments/<sessionID>/<uuid>.<ext>`，
/// 与会话 JSONL 目录（`~/.new-pi/agent/sessions/<projectHash>/`）同层级。
public enum SessionAttachments {
    /// 附件根目录（`sessionsRoot/attachments`），按需创建。
    public static func root(
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory
    ) throws -> URL {
        let root = SessionManager.sessionsRoot(agentDirectory: agentDirectory)
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 某会话的附件子目录，按需创建。
    public static func directory(
        for sessionID: UUID,
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory
    ) throws -> URL {
        let dir = try root(agentDirectory: agentDirectory)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 相对附件根目录的路径 → 绝对文件 URL（受控解析）。
    ///
    /// - 相对路径不得以 `/` 开头，不得包含 `..` 路径段（标准化后仍逃出附件根目录则拒绝）。
    /// - 返回 nil 表示路径非法（路径穿越或格式错误），调用方应视为「附件不可读」。
    public static func resolve(
        relativePath: String,
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory
    ) -> URL? {
        // 仅允许相对路径；拒绝绝对路径与 query/fragment。
        if relativePath.hasPrefix("/") { return nil }
        guard let root = try? root(agentDirectory: agentDirectory) else { return nil }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootStandardized = root.standardizedFileURL
        // 标准化后必须仍在附件根目录内（阻断 `../` 穿越）。
        guard candidate.path.hasPrefix(rootStandardized.path + "/") else { return nil }
        return candidate
    }

    /// 读取附件文件字节（受控）。路径非法或文件不存在返回 nil。
    public static func data(
        for attachment: MessageAttachment,
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory
    ) -> Data? {
        guard let url = resolve(relativePath: attachment.path, agentDirectory: agentDirectory) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
