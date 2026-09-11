import CryptoKit
import Foundation

public struct EditSnapshotStore: Sendable {
    // 同进程的 Session/聊天室可能同时编辑；创建与裁剪必须是一个临界区。
    private static let lock = NSLock()
    private static let sourceMetadataName = "source-path.txt"
    /// 保留策略：控制快照目录不会无限增长。
    public struct RetentionPolicy: Sendable {
        /// 每个被编辑文件最多保留的最近快照数量。必须大于零，`nil` 表示不限制。
        public var maxPerFile: Int?
        /// 快照最大保留天数。必须大于零，`nil` 表示不限制。
        public var maxAgeDays: Int?

        public init(maxPerFile: Int? = 20, maxAgeDays: Int? = 30) {
            self.maxPerFile = maxPerFile
            self.maxAgeDays = maxAgeDays
        }

        public static let unlimited = RetentionPolicy(maxPerFile: nil, maxAgeDays: nil)
    }

    public var rootDirectory: URL
    public var retentionPolicy: RetentionPolicy

    public init(rootDirectory: URL, retentionPolicy: RetentionPolicy = RetentionPolicy()) {
        self.rootDirectory = rootDirectory
        self.retentionPolicy = retentionPolicy
    }

    public static func forProject(
        _ projectDirectory: URL,
        retentionPolicy: RetentionPolicy = RetentionPolicy()
    ) -> EditSnapshotStore {
        let root = projectDirectory
            .appendingPathComponent(NewPiConfig.projectConfigDirectoryName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        return EditSnapshotStore(rootDirectory: root, retentionPolicy: retentionPolicy)
    }

    public func snapshotBeforeEdit(sourceFile: URL) throws -> URL {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try validatePolicy()

        let fm = FileManager.default
        let source = sourceFile.standardizedFileURL.resolvingSymlinksInPath()
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(Self.directoryName(for: source.path), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard directoryValues.isSymbolicLink != true else {
            throw AgentError.invalidState("Snapshot directory must not be a symbolic link")
        }
        let metadata = directory.appendingPathComponent(Self.sourceMetadataName)
        if fm.fileExists(atPath: metadata.path) {
            let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  try String(contentsOf: metadata, encoding: .utf8) == source.path else {
                throw AgentError.invalidState("Snapshot source metadata does not match the edited file")
            }
        } else {
            try source.path.write(to: metadata, atomically: true, encoding: .utf8)
        }

        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent("\(timestamp)-\(UUID().uuidString).snapshot")

        if fm.fileExists(atPath: source.path) {
            try fm.copyItem(at: source, to: destination)
        } else {
            try Data().write(to: destination)
        }
        // copyItem 会保留源文件的修改时间，不能用它判断备份先后。
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: destination.path)
        let savedURL = destination.resolvingSymlinksInPath()
        pruneLocked(now: now, preserving: savedURL)
        return savedURL
    }

    /// 按保留策略裁剪历史快照。失败时不抛出，避免影响编辑主流程。
    @discardableResult
    public func prune(now: Date = Date()) -> [URL] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            try validatePolicy()
        } catch {
            logPruneFailure(error)
            return []
        }
        return pruneLocked(now: now, preserving: nil)
    }

    private func validatePolicy() throws {
        guard retentionPolicy.maxPerFile.map({ $0 > 0 }) ?? true,
              retentionPolicy.maxAgeDays.map({ $0 > 0 }) ?? true else {
            throw AgentError.invalidState("Snapshot retention limits must be positive or nil")
        }
    }

    private func pruneLocked(now: Date, preserving protectedURL: URL?) -> [URL] {
        let policy = retentionPolicy
        guard policy.maxPerFile != nil || policy.maxAgeDays != nil else { return [] }
        let fm = FileManager.default
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: root.path) else { return [] }
        let directories: [URL]
        do {
            directories = try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            logPruneFailure(error)
            return []
        }

        var toDelete: Set<URL> = []
        // 旧平铺快照没有源路径身份，无法安全分配配额；不自动迁移或清理。
        for directory in directories where Self.isManagedDirectory(directory.lastPathComponent) {
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let metadata = directory.appendingPathComponent(Self.sourceMetadataName)
                let metadataValues = try metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard metadataValues.isRegularFile == true, metadataValues.isSymbolicLink != true else { continue }
                let sourcePath = try String(contentsOf: metadata, encoding: .utf8)
                guard Self.directoryName(for: sourcePath) == directory.lastPathComponent else {
                    throw AgentError.invalidState("Snapshot source metadata does not match its directory")
                }
                let files = try fm.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                var entries: [(url: URL, date: Date, modified: Date)] = []
                for file in files {
                    guard let date = Self.snapshotDate(from: file.lastPathComponent) else { continue }
                    let values = try file.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey
                    ])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    // 目录枚举可能返回 /private/var，调用方则持有 /var；比较前统一别名。
                    let canonicalFile = file.standardizedFileURL.resolvingSymlinksInPath()
                    entries.append((canonicalFile, date, values.contentModificationDate ?? date))
                }
                if let days = policy.maxAgeDays {
                    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                    for entry in entries where entry.date < cutoff {
                        toDelete.insert(entry.url)
                    }
                }
                if let limit = policy.maxPerFile {
                    let sorted = entries.sorted {
                        if $0.url == protectedURL { return $1.url != protectedURL }
                        if $1.url == protectedURL { return false }
                        if $0.modified != $1.modified { return $0.modified > $1.modified }
                        return $0.url.lastPathComponent > $1.url.lastPathComponent
                    }
                    for entry in sorted.dropFirst(limit) {
                        toDelete.insert(entry.url)
                    }
                }
            } catch {
                logPruneFailure(error)
            }
        }
        if let protectedURL { toDelete.remove(protectedURL) }

        var removed: [URL] = []
        for url in toDelete {
            do {
                try fm.removeItem(at: url)
                removed.append(url)
            } catch {
                logPruneFailure(error)
            }
        }
        return removed
    }

    private func logPruneFailure(_ error: Error) {
        NewPiLogger.error(category: "snapshot", message: "Snapshot retention cleanup failed",
            details: error.localizedDescription)
    }

    private static func isManagedDirectory(_ name: String) -> Bool {
        name.hasPrefix("v2-") && name.count == 67
            && name.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func directoryName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "v2-\(digest)"
    }

    private static func snapshotDate(from name: String) -> Date? {
        guard name.hasSuffix(".snapshot"), name.count == 66 else { return nil }
        let raw = String(name.prefix(20))
        guard name[name.index(name.startIndex, offsetBy: 20)] == "-",
              UUID(uuidString: String(name.dropFirst(21).prefix(36))) != nil else { return nil }
        guard let tIndex = raw.firstIndex(of: "T") else { return nil }
        let datePart = String(raw[raw.startIndex...tIndex])
        let timePart = String(raw[raw.index(after: tIndex)...])
            .replacingOccurrences(of: "-", with: ":")
        return ISO8601DateFormatter().date(from: datePart + timePart)
    }
}
