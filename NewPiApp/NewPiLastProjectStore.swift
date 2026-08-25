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
