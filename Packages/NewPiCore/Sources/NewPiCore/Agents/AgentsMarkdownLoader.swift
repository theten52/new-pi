import Foundation

/// Loads project-specific agent instructions from `AGENTS.md` files.
public enum AgentsMarkdownLoader {
    public static let fileName = "AGENTS.md"
    public static let projectConfigRelativePath = ".new-pi/AGENTS.md"

    public enum Source: String, Sendable, Equatable {
        case projectConfig
        case projectRoot
    }

    public struct LoadedInstructions: Sendable, Equatable {
        public var content: String
        public var source: Source
        public var fileURL: URL

        public init(content: String, source: Source, fileURL: URL) {
            self.content = content
            self.source = source
            self.fileURL = fileURL
        }
    }

    /// Search order: `<project>/.new-pi/AGENTS.md`, then `<project>/AGENTS.md`.
    public static func load(
        from projectDirectory: URL,
        fileManager: FileManager = .default
    ) -> LoadedInstructions? {
        let candidates: [(URL, Source)] = [
            (
                projectDirectory.appendingPathComponent(projectConfigRelativePath),
                .projectConfig
            ),
            (
                projectDirectory.appendingPathComponent(fileName),
                .projectRoot
            ),
        ]

        for (url, source) in candidates {
            guard fileManager.fileExists(atPath: url.path),
                  let data = fileManager.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8)
            else {
                continue
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            return LoadedInstructions(content: trimmed, source: source, fileURL: url)
        }

        return nil
    }

    public static func composeSystemPrompt(
        for projectDirectory: URL,
        base: String = BuiltInTools.defaultSystemPrompt,
        fileManager: FileManager = .default
    ) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let instructions = load(from: projectDirectory, fileManager: fileManager) else {
            return trimmedBase
        }

        return """
        \(trimmedBase)

        ## Project instructions (AGENTS.md)

        \(instructions.content)
        """
    }
}
