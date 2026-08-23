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
}
