import Foundation
import Testing
@testable import NewPiCore

@Suite("SkillFrontmatterParser")
struct SkillFrontmatterParserTests {
    @Test("parses frontmatter and body")
    func parseFrontmatter() {
        let text = """
        ---
        name: Swift Style
        description: Follow Swift 6 conventions
        enabled: true
        ---

        Always prefer `Sendable` types.
        """
        let parsed = SkillFrontmatterParser.parse(text)
        #expect(parsed.frontmatter["name"] == "Swift Style")
        #expect(parsed.frontmatter["enabled"] == "true")
        #expect(parsed.body.contains("Sendable"))
    }
}

@Suite("SkillsLoader")
struct SkillsLoaderTests {
    @Test("discovers user and project skills with project override")
    func discoverAndOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agentDir = root.appendingPathComponent("agent", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)

        let userSkillDir = agentDir.appendingPathComponent("skills/shared-skill", isDirectory: true)
        let projectSkillDir = project.appendingPathComponent(".new-pi/skills/shared-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: userSkillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSkillDir, withIntermediateDirectories: true)

        try """
        ---
        name: User Copy
        ---
        user body
        """.write(to: userSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        try """
        ---
        name: Project Copy
        ---
        project body
        """.write(to: projectSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = SkillsLoader.discover(
            projectDirectory: project,
            agentDirectory: agentDir
        )
        #expect(skills.count == 1)
        #expect(skills[0].source == .project)
        #expect(skills[0].content == "project body")
    }

    @Test("disabled skills are excluded from enabledSkills")
    func disabledSkills() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agentDir = root.appendingPathComponent("agent", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let skillDir = agentDir.appendingPathComponent("skills/off", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        enabled: false
        ---
        hidden
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let enabled = SkillsLoader.enabledSkills(projectDirectory: project, agentDirectory: agentDir)
        #expect(enabled.isEmpty)
    }
}

@Suite("SystemPromptComposer")
struct SystemPromptComposerTests {
    @Test("includes agents and skills sections")
    func composeAll() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agentDir = root.appendingPathComponent("agent", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try "Project rules".write(
            to: project.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        let skillDir = agentDir.appendingPathComponent("skills/test-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: Test Skill
        ---
        Do the thing.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let composed = SystemPromptComposer.compose(
            for: project,
            base: "BASE",
            agentDirectory: agentDir
        )

        #expect(composed.text.contains("BASE"))
        #expect(composed.text.contains("Project instructions"))
        #expect(composed.text.contains("Project rules"))
        #expect(composed.text.contains("## Skills"))
        #expect(composed.text.contains("Test Skill"))
        #expect(composed.skills.count == 1)
        #expect(composed.agents != nil)
    }
}
