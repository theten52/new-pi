import Foundation

/// 聊天室自己的目录，与 Session 当前项目无关。检查不创建目录、不写测试文件。
public enum ChatRoomWorkingDirectory {
    public enum Issue: String, Error, LocalizedError, Sendable {
        case invalidPath, missing, notDirectory, inaccessible

        public var errorDescription: String? {
            switch self {
            case .invalidPath: "工作目录路径无效，请使用绝对路径。"
            case .missing: "工作目录不存在，可能已移动、重命名或磁盘未连接。"
            case .notDirectory: "工作目录路径指向文件，而不是文件夹。"
            case .inaccessible: "无法读取或进入工作目录，请检查目录权限。"
            }
        }
    }

    public static func issue(for path: String, fileManager: FileManager = .default) -> Issue? {
        let expanded = (path as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return .invalidPath }
        // 用 attributes 区分权限错误和不存在；解析符号链接也能识别断链。
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return .notDirectory }
            guard fileManager.isReadableFile(atPath: url.path),
                  fileManager.isExecutableFile(atPath: url.path) else { return .inaccessible }
            return nil
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
                return .missing
            }
            return .inaccessible
        }
    }

    /// 分组只规范路径，不按文件夹短名称合并，避免两个不同目录同名时混在一起。
    /// 不解析符号链接：磁盘断开/恢复时仍保留同一分组身份。
    public static func groupID(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return path }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
