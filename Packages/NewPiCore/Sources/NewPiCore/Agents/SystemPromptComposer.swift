import Foundation

public struct ComposedSystemPrompt: Sendable, Equatable {
    public var text: String
    public var agents: AgentsMarkdownLoader.LoadedInstructions?
    public var skills: [SkillDefinition]

    public init(text: String, agents: AgentsMarkdownLoader.LoadedInstructions?, skills: [SkillDefinition]) {
        self.text = text
        self.agents = agents
        self.skills = skills
    }
}

public enum SystemPromptComposer {
    public static func compose(
        for projectDirectory: URL,
        base: String = BuiltInTools.defaultSystemPrompt,
        agentDirectory: URL = NewPiConfig.defaultAgentDirectory,
        fileManager: FileManager = .default
    ) -> ComposedSystemPrompt {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = [trimmedBase]
        let agents = AgentsMarkdownLoader.load(from: projectDirectory, fileManager: fileManager)
        let skills = SkillsLoader.enabledSkills(
            projectDirectory: projectDirectory,
            agentDirectory: agentDirectory,
            fileManager: fileManager
        )

        if let agents {
            sections.append(
                """

                ## Project instructions (AGENTS.md)

                \(agents.content)
                """
            )
        }

        if !skills.isEmpty {
            let skillBlocks = skills.map { skill in
                """
                ### Skill: \(skill.name)

                \(skill.content)
                """
            }.joined(separator: "\n\n")

            sections.append(
                """

                ## Skills

                \(skillBlocks)
                """
            )
        }

        return ComposedSystemPrompt(
            text: sections.joined(),
            agents: agents,
            skills: skills
        )
    }
}
