import Foundation

/// Appends sanitized log lines to disk so agents and users can inspect runs after the fact.
public final class NewPiFileLogSink: @unchecked Sendable {
    public static let shared = NewPiFileLogSink()

    private let lock = NSLock()
    private var isEnabled = false
    private var sessionID = ""
    private var projectDirectory: URL?
    private var hasWrittenSessionHeader = false

    public static let logFileName = "newpi-debug.log"
    public static let projectLogFileName = "debug.log"
    public static let maxFileBytes = 5 * 1024 * 1024

    private init() {}

    public var globalLogURL: URL {
        lock.lock()
        let override = logsDirectoryOverride
        lock.unlock()
        return (override ?? Self.defaultLogsDirectory).appendingPathComponent(Self.logFileName)
    }

    /// 测试用：重定向全局日志目录，避免测试读写真实 ~/.new-pi/agent/logs。
    public func setLogsDirectoryOverride(_ url: URL?) {
        lock.lock()
        logsDirectoryOverride = url
        lock.unlock()
    }

    private var logsDirectoryOverride: URL?

    public static var defaultLogsDirectory: URL {
        NewPiConfig.defaultAgentDirectory
            .appendingPathComponent("logs", isDirectory: true)
    }

    public func projectLogURL(for projectDirectory: URL) -> URL {
        projectDirectory
            .appendingPathComponent(NewPiConfig.projectConfigDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.projectLogFileName)
    }

    public var activeLogURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        let base = logsDirectoryOverride ?? Self.defaultLogsDirectory
        var urls = [base.appendingPathComponent(Self.logFileName)]
        if let projectDirectory {
            urls.append(projectLogURL(for: projectDirectory))
        }
        return urls
    }

    public func enable(sessionID: String) {
        lock.lock()
        self.isEnabled = true
        self.sessionID = sessionID
        self.hasWrittenSessionHeader = false
        lock.unlock()

        rotateIfNeeded(at: globalLogURL)
        writeSessionHeader(to: globalLogURL)
    }

    public func setProjectDirectory(_ url: URL?) {
        lock.lock()
        let previous = projectDirectory
        projectDirectory = url?.standardizedFileURL
        lock.unlock()

        guard let projectDirectory else { return }
        let projectLog = projectLogURL(for: projectDirectory)
        rotateIfNeeded(at: projectLog)

        if previous?.path != projectDirectory.path {
            writeSessionHeader(to: projectLog, label: "project attached")
        }
    }

    public func append(_ entry: NewPiLogEntry) {
        lock.lock()
        guard isEnabled else {
            lock.unlock()
            return
        }
        let projectDirectory = projectDirectory
        lock.unlock()

        let line = entry.formattedMessage + "\n"
        appendLine(line, to: globalLogURL)
        if let projectDirectory {
            appendLine(line, to: projectLogURL(for: projectDirectory))
        }
    }

    private func writeSessionHeader(to url: URL, label: String = "session started") {
        lock.lock()
        let sessionID = sessionID
        let projectPath = projectDirectory?.path
        lock.unlock()

        let formatter = ISO8601DateFormatter()
        var header = """
        ================================================================================
        [\(formatter.string(from: Date()))] [INFO] [lifecycle] NewPi \(label)
        Session ID: \(sessionID)
        Global log: \(globalLogURL.path)
        """
        if let projectPath {
            header += "\nProject: \(projectPath)"
            header += "\nProject log: \(projectLogURL(for: URL(fileURLWithPath: projectPath)).path)"
        }
        header += "\n================================================================================\n"
        appendLine(header, to: url)
    }

    private func appendLine(_ line: String, to url: URL) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Avoid recursive logging if file I/O fails.
        }
    }

    private func rotateIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > Self.maxFileBytes else {
            return
        }

        let backup = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
