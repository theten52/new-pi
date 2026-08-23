import Foundation

public struct EditSnapshotStore: Sendable {
    public var rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func forProject(_ projectDirectory: URL) -> EditSnapshotStore {
        let root = projectDirectory
            .appendingPathComponent(NewPiConfig.projectConfigDirectoryName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        return EditSnapshotStore(rootDirectory: root)
    }

    public func snapshotBeforeEdit(sourceFile: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileName = sourceFile.lastPathComponent
        let snapshotName = "\(timestamp)-\(fileName)"
        let destination = rootDirectory.appendingPathComponent(snapshotName)

        if fm.fileExists(atPath: sourceFile.path) {
            try fm.copyItem(at: sourceFile, to: destination)
        } else {
            try Data().write(to: destination)
        }

        return destination
    }
}
