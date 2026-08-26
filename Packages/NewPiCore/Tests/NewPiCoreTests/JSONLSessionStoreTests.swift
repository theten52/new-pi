import Foundation
import Testing
@testable import NewPiCore

@Suite("JSONLSessionCodec")
struct JSONLSessionCodecTests {
    @Test("round-trips header and message entries")
    func roundTrip() throws {
        let header = SessionHeader(
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            providerProfileID: "anthropic-default",
            modelID: "claude-sonnet-4-20250514",
            label: "Test session"
        )
        var context = SessionContext(header: header)
        _ = SessionManager.appendMessage(.user("你好"), to: &context, parentID: nil)

        let codec = JSONLSessionCodec()
        let data = try codec.encode(context)
        let loaded = try codec.decode(data)

        #expect(loaded.header.id == header.id)
        #expect(loaded.header.providerProfileID == "anthropic-default")
        #expect(loaded.entries.count == 1)
        #expect(loaded.leafID == loaded.entries.first?.id)
        #expect(SessionManager.messages(from: loaded).count == 1)
    }

    @Test("decodes legacy session written before reasoningContent field existed")
    func legacySessionWithoutReasoningContent() throws {
        // Reproduces the on-disk format produced by an older `AssistantMessage`
        // that predated the `reasoningContent` property. The synthesized Codable
        // would have failed on the assistant entry; the tolerant decoder must not.
        let legacyJSONL = """
        {"header":{"createdAt":"2026-08-25T22:37:54Z","id":"F7BB77CD-D89A-4753-814D-8AF5BADC1672","modelID":"deepseek-v4-flash-vision-exp","providerProfileID":"FC50D42A-8332-49D4-A2C0-D9760F6066D3","version":1,"workingDirectory":"file:///tmp/project"},"recordType":"header"}
        {"entry":{"id":"e2d61a51","message":{"user":{"_0":{"content":"你好","timestamp":"2026-08-25T22:38:01Z"}}},"timestamp":"2026-08-25T22:38:03Z","type":"message"},"recordType":"entry"}
        {"entry":{"id":"c982ecd8","parentID":"e2d61a51","message":{"assistant":{"_0":{"modelID":"deepseek-v4-flash-vision-exp","provider":"openaiCompatible","stopReason":"stop","text":"你好！","timestamp":"2026-08-25T22:38:03Z","toolCalls":[],"usage":{"inputTokens":0,"outputTokens":0}}}},"timestamp":"2026-08-25T22:38:03Z","type":"message"},"recordType":"entry"}
        """
        let codec = JSONLSessionCodec()
        let context = try codec.decode(Data(legacyJSONL.utf8))

        let messages = SessionManager.messages(from: context)
        #expect(messages.count == 2)
        guard case let .assistant(assistant) = messages.last else {
            Issue.record("expected assistant message as last entry")
            return
        }
        // Missing field must default to empty string, not fail decode.
        #expect(assistant.reasoningContent == "")
        #expect(assistant.text == "你好！")
    }

    @Test("branch preserves message order")
    func branchOrder() throws {
        var context = SessionContext(
            header: SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        )
        var parent: String?
        for text in ["one", "two", "three"] {
            let entry = SessionManager.appendMessage(.user(text), to: &context, parentID: parent)
            parent = entry.id
        }

        let messages = SessionManager.messages(from: context)
        #expect(messages.count == 3)
        #expect(messages.compactMap { message -> String? in
            if case let .user(user) = message { return user.content }
            return nil
        } == ["one", "two", "three"])
    }
}

@Suite("SessionManager")
struct SessionManagerTests {
    @Test("creates session file under project hash directory")
    func createSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/new-pi-test-project")

        let (context, fileURL) = try SessionManager.createSession(
            workingDirectory: project,
            providerProfileID: "deepseek",
            modelID: "deepseek-chat",
            root: root
        )

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(context.header.workingDirectory == project.standardizedFileURL)
        #expect(fileURL.path.contains(SessionManager.projectHash(for: project)))
    }

    @Test("lists sessions sorted by recency")
    func listSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/new-pi-list-test")
        let store = JSONLSessionStore()

        _ = try SessionManager.createSession(workingDirectory: project, label: "first", root: root, store: store)
        _ = try SessionManager.createSession(workingDirectory: project, label: "second", root: root, store: store)

        let summaries = try SessionManager.listSessions(for: project, root: root, store: store)
        #expect(summaries.count == 2)
        #expect(summaries.allSatisfy { $0.messageCount == 0 })
    }

    @Test("project hash is stable")
    func projectHashStable() {
        let url = URL(fileURLWithPath: "/tmp/stable")
        #expect(SessionManager.projectHash(for: url) == SessionManager.projectHash(for: url))
    }
}

@Suite("SessionManager sync")
struct SessionManagerSyncTests {
    @Test("rebuilds linear entries from agent messages")
    func rebuildFromMessages() {
        let header = SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        let messages: [AgentMessage] = [
            .user("hi"),
            .assistant(
                AssistantMessage(
                    text: "hello",
                    provider: "anthropic",
                    modelID: "claude",
                    stopReason: .stop
                )
            ),
        ]
        let context = SessionManager.rebuildContext(from: messages, header: header)
        #expect(context.entries.count == 2)
        #expect(SessionManager.messages(from: context).count == 2)
    }
}
