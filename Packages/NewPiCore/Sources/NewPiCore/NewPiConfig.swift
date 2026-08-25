import Foundation

/// Shared configuration constants for the new-pi harness.
public enum NewPiConfig {
    /// User-level config root, e.g. `~/.new-pi/agent/`.
    public static let agentDirectoryName = ".new-pi"

    public static var defaultAgentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(agentDirectoryName, isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    /// Project-local config directory name.
    public static let projectConfigDirectoryName = ".new-pi"

    /// User-level debug log directory, e.g. `~/.new-pi/agent/logs/`.
    public static var defaultLogsDirectory: URL {
        NewPiFileLogSink.defaultLogsDirectory
    }

    /// Primary persistent debug log file path.
    public static var defaultDebugLogFile: URL {
        defaultLogsDirectory.appendingPathComponent(NewPiFileLogSink.logFileName)
    }

    public static func projectDebugLogFile(in projectDirectory: URL) -> URL {
        NewPiFileLogSink.shared.projectLogURL(for: projectDirectory)
    }
}
