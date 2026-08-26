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

    @Test("loadSummary message count matches full decode")
    func loadSummaryMessageCount() throws {
        var context = SessionContext(
            header: SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp/project"), label: "summary test")
        )
        _ = SessionManager.appendMessage(.user("one"), to: &context, parentID: nil)
        _ = SessionManager.appendMessage(
            .assistant(
                AssistantMessage(
                    text: "two",
                    provider: "anthropic",
                    modelID: "claude",
                    stopReason: .stop
                )
            ),
            to: &context,
            parentID: context.leafID
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = SessionManager.makeSessionFileURL(
            in: root,
            sessionID: context.header.id,
            createdAt: context.header.createdAt
        )
        let store = JSONLSessionStore()
        try store.save(context, to: fileURL)

        let summary = try store.loadSummary(from: fileURL)
        let loaded = try store.load(from: fileURL)

        #expect(summary.id == context.header.id)
        #expect(summary.label == "summary test")
        #expect(summary.messageCount == SessionManager.messages(from: loaded).count)
        #expect(summary.messageCount == 2)
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

    @Test("archived sessions are hidden from default list")
    func archivedSessionsHidden() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/new-pi-archive-test")
        let store = JSONLSessionStore()

        let (_, activeURL) = try SessionManager.createSession(
            workingDirectory: project,
            label: "active",
            root: root,
            store: store
        )
        let (_, archivedURL) = try SessionManager.createSession(
            workingDirectory: project,
            label: "archived",
            root: root,
            store: store
        )
        try SessionManager.setArchived(true, for: archivedURL, store: store)

        let visible = try SessionManager.listSessions(for: project, root: root, store: store)
        let all = try SessionManager.listSessions(
            for: project,
            root: root,
            store: store,
            includeArchived: true
        )

        #expect(visible.count == 1)
        #expect(visible.first?.fileURL.standardizedFileURL == activeURL.standardizedFileURL)
        #expect(all.count == 2)
    }

    @Test("deleteEmptySessions removes header-only files")
    func deleteEmptySessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/new-pi-delete-empty-test")
        let store = JSONLSessionStore()

        let (_, emptyURL) = try SessionManager.createSession(workingDirectory: project, root: root, store: store)
        var context = SessionContext(
            header: SessionHeader(workingDirectory: project, label: "with messages")
        )
        _ = SessionManager.appendMessage(.user("hello"), to: &context, parentID: nil)
        let nonemptyURL = SessionManager.makeSessionFileURL(
            in: SessionManager.projectDirectory(for: project, root: root),
            sessionID: context.header.id,
            createdAt: context.header.createdAt
        )
        try store.save(context, to: nonemptyURL)

        let deleted = try SessionManager.deleteEmptySessions(for: project, root: root, store: store)
        #expect(deleted == 1)
        #expect(FileManager.default.fileExists(atPath: emptyURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: nonemptyURL.path))
    }

    @Test("updateLabel persists in session header")
    func updateLabel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/new-pi-label-test")
        let store = JSONLSessionStore()
        let (_, fileURL) = try SessionManager.createSession(workingDirectory: project, root: root, store: store)

        try SessionManager.updateLabel("自动命名测试", for: fileURL, store: store)
        let summary = try store.loadSummary(from: fileURL)

        #expect(summary.label == "自动命名测试")
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
