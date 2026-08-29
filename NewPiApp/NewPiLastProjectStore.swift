import Foundation

enum NewPiLastProjectStore {
    private static let pathDefaultsKey = "com.new-pi.lastProjectPath"

    static func save(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: pathDefaultsKey)
    }

    static func load(fileManager: FileManager = .default) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: pathDefaultsKey) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            UserDefaults.standard.removeObject(forKey: pathDefaultsKey)
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

/// 按项目记录「最后活跃的 Session 文件」，用于打开 App / 打开项目时
/// 自动恢复上次离开时的会话。
enum NewPiLastSessionStore {
    /// UserDefaults 结构：[projectPath: sessionFilePath]
    private static let defaultsKey = "com.new-pi.lastSessionPaths"

    static func save(sessionFileURL: URL, for projectURL: URL) {
        var map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        map[projectURL.standardizedFileURL.path] = sessionFileURL.standardizedFileURL.path
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    static func load(for projectURL: URL) -> URL? {
        let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard let path = map[projectURL.standardizedFileURL.path] else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func clear(for projectURL: URL) {
        var map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        map.removeValue(forKey: projectURL.standardizedFileURL.path)
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}
