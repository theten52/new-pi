import Foundation

public enum SkillSource: String, Sendable, Codable, Equatable {
    case userAgent
    case project
}

public struct SkillDefinition: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var content: String
    public var source: SkillSource
    public var fileURL: URL
    public var enabled: Bool

    public init(
        id: String,
        name: String,
        description: String,
        content: String,
        source: SkillSource,
        fileURL: URL,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.content = content
        self.source = source
        self.fileURL = fileURL
        self.enabled = enabled
    }
}

/// Extension point for future native tools, slash commands, and lifecycle hooks.
public protocol NewPiExtension: Sendable {
    var id: String { get }
    var displayName: String { get }
}

/// Markdown-backed skill loaded from disk.
public struct NewPiMarkdownSkill: NewPiExtension, Sendable, Equatable {
    public var definition: SkillDefinition

    public var id: String { definition.id }
    public var displayName: String { definition.name }
    public var instructions: String { definition.content }

    public init(definition: SkillDefinition) {
        self.definition = definition
    }
}

public enum SkillFrontmatterParser {
    public static func parse(_ text: String) -> (frontmatter: [String: String], body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return ([:], trimmed)
        }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else {
            return ([:], trimmed)
        }
        lines.removeFirst()

        var frontmatter: [String: String] = [:]
        while let line = lines.first, line != "---" {
            lines.removeFirst()
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            frontmatter[parts[0].lowercased()] = parts[1]
        }

        if !lines.isEmpty, lines.first == "---" {
            lines.removeFirst()
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontmatter, body)
    }
}

public enum SkillsLoader {
    public static let skillFileName = "SKILL.md"
    public static let userSkillsDirectoryName = "skills"
    public static let projectSkillsRelativePath = ".new-pi/skills"

    public static func userSkillsRoot(agentDirectory: URL = NewPiConfig.defaultAgentDirectory) -> URL {
        agentDirectory.appendingPathComponent(userSkillsDirectoryName, isDirectory: true)
    }

    public static func projectSkillsRoot(for projectDirectory: URL) -> URL {
        projectDirectory.appendingPathComponent(projectSkillsRelativePath, isDirectory: true)
    }

    public static func discover(
        projectDirectory: URL,
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory,
        fileManager: FileManager = .default
    ) -> [SkillDefinition] {
        var byID: [String: SkillDefinition] = [:]

        loadSkills(from: userSkillsRoot(agentDirectory: agentDirectory), source: .userAgent, fileManager: fileManager)
            .forEach { byID[$0.id] = $0 }

        loadSkills(from: projectSkillsRoot(for: projectDirectory), source: .project, fileManager: fileManager)
            .forEach { byID[$0.id] = $0 }

        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func enabledSkills(
        projectDirectory: URL,
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory,
        fileManager: FileManager = .default
    ) -> [SkillDefinition] {
        discover(projectDirectory: projectDirectory, agentDirectory: agentDirectory, fileManager: fileManager)
            .filter(\.enabled)
    }

    private static func loadSkills(
        from directory: URL,
        source: SkillSource,
        fileManager: FileManager
    ) -> [SkillDefinition] {
        guard fileManager.fileExists(atPath: directory.path),
              let entries = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        var skills: [SkillDefinition] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let skillFile = entry.appendingPathComponent(skillFileName)
            guard fileManager.fileExists(atPath: skillFile.path),
                  let data = fileManager.contents(atPath: skillFile.path),
                  let text = String(data: data, encoding: .utf8)
            else {
                continue
            }

            let parsed = SkillFrontmatterParser.parse(text)
            let body = parsed.body
            guard !body.isEmpty else { continue }

            let id = entry.lastPathComponent
            let name = parsed.frontmatter["name"] ?? id
            let description = parsed.frontmatter["description"] ?? ""
            let enabled = parseEnabled(parsed.frontmatter["enabled"], defaultValue: true)

            skills.append(
                SkillDefinition(
                    id: id,
                    name: name,
                    description: description,
                    content: body,
                    source: source,
                    fileURL: skillFile,
                    enabled: enabled
                )
            )
        }

        return skills
    }

    private static func parseEnabled(_ value: String?, defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        switch value.lowercased() {
        case "true", "yes", "1", "on":
            return true
        case "false", "no", "0", "off":
            return false
        default:
            return defaultValue
        }
    }
}
