import Foundation
import Testing
@testable import NewPiCore

@Suite("AgentsMarkdownLoader")
struct AgentsMarkdownLoaderTests {
    @Test("returns base prompt when no AGENTS.md exists")
    func missingFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let prompt = AgentsMarkdownLoader.composeSystemPrompt(for: directory, base: "BASE")
        #expect(prompt == "BASE")
        #expect(AgentsMarkdownLoader.load(from: directory) == nil)
    }

    @Test("loads project root AGENTS.md")
    func projectRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let agentsURL = directory.appendingPathComponent("AGENTS.md")
        try "Use Swift 6 strict concurrency.".write(to: agentsURL, atomically: true, encoding: .utf8)

        let loaded = try #require(AgentsMarkdownLoader.load(from: directory))
        #expect(loaded.source == .projectRoot)
        #expect(loaded.content.contains("Swift 6"))

        let prompt = AgentsMarkdownLoader.composeSystemPrompt(for: directory, base: "BASE")
        #expect(prompt.contains("BASE"))
        #expect(prompt.contains("Project instructions"))
        #expect(prompt.contains("Swift 6"))
    }

    @Test("prefers .new-pi/AGENTS.md over project root")
    func projectConfigPriority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDir = directory.appendingPathComponent(".new-pi", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        try "root instructions".write(
            to: directory.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )
        try "local override".write(
            to: configDir.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        let loaded = try #require(AgentsMarkdownLoader.load(from: directory))
        #expect(loaded.source == .projectConfig)
        #expect(loaded.content == "local override")
    }
}
