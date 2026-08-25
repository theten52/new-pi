import Foundation
import Testing
@testable import NewPiCore

@Suite("SessionBranch")
struct SessionBranchTests {
    @Test("fork preserves sibling entries")
    func forkPreservesSiblings() throws {
        var context = SessionContext(
            header: SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        )
        let first = SessionManager.appendMessage(.user("one"), to: &context, parentID: nil)
        _ = SessionManager.appendMessage(.user("two"), to: &context, parentID: first.id)
        let forkPoint = first.id

        var forked = try SessionManager.forkContext(context, at: forkPoint)
        _ = SessionManager.appendMessage(.user("branch"), to: &forked, parentID: forkPoint)

        #expect(forked.entries.count == 3)
        #expect(SessionManager.childEntries(of: forkPoint, in: forked).count == 2)
        #expect(SessionManager.branchPointCount(in: forked) == 1)

        let mainMessages = SessionManager.messages(from: context)
        let branchMessages = SessionManager.messages(from: forked, leafID: forked.leafID)
        #expect(mainMessages.count == 2)
        #expect(branchMessages.map { messageText($0) } == ["one", "branch"])
    }

    @Test("syncMessages appends without rewriting history")
    func syncAppends() {
        var context = SessionContext(
            header: SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        )
        var leafID: String?
        SessionManager.syncMessages([.user("a")], into: &context, leafID: &leafID)
        SessionManager.syncMessages([.user("a"), .user("b")], into: &context, leafID: &leafID)

        #expect(context.entries.count == 2)
        #expect(SessionManager.messages(from: context, leafID: leafID).count == 2)
    }

    private func messageText(_ message: AgentMessage) -> String? {
        if case let .user(user) = message { return user.content }
        return nil
    }
}

@Suite("SessionExporter")
struct SessionExporterTests {
    @Test("exports markdown with header")
    func markdownExport() {
        let header = SessionHeader(
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            label: "demo"
        )
        let context = SessionContext(header: header)
        let messages: [AgentMessage] = [.user("hello"), .assistant(
            AssistantMessage(
                text: "hi",
                provider: "anthropic",
                modelID: "claude",
                stopReason: .stop
            )
        )]

        let output = SessionExporter().exportMarkdown(context: context, messages: messages)
        #expect(output.contains("# NewPi Session"))
        #expect(output.contains("### You"))
        #expect(output.contains("hello"))
        #expect(output.contains("### NewPi"))
    }

    @Test("exports JSON session context")
    func jsonExport() throws {
        let context = SessionContext(
            header: SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        )
        let data = try SessionExporter().exportJSON(context: context)
        #expect(!data.isEmpty)
    }
}

@Suite("SubAgentTool")
struct SubAgentToolTests {
    @Test("returns sub-agent reply")
    func subAgentReply() async throws {
        let llm = MockLLMProviderBox(scripts: [[
            .textDelta("Found 3 files."),
            .completed(stopReason: .stop, usage: UsageStats()),
        ]])

        let tool = SubAgentTool(llm: llm, model: AgentLoopTestSupport.defaultModel, maxTurns: 3)
        let result = try await tool.execute(
            id: "sub_1",
            arguments: .object(["task": .string("List files")]),
            context: ToolContext(workingDirectory: URL(fileURLWithPath: "/tmp")),
            onUpdate: nil
        )

        #expect(result.isError == false)
        #expect(result.content.contains("Found 3 files"))
    }
}
