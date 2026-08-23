import Foundation
import Testing
@testable import NewPiCore

@Suite("SessionManager findSession")
struct SessionManagerFindSessionTests {
    @Test("finds session by id prefix")
    func findByPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/new-pi-find-test")
        let store = JSONLSessionStore()

        let created = try SessionManager.createSession(
            workingDirectory: project,
            label: "target",
            root: root,
            store: store
        )
        _ = try SessionManager.createSession(workingDirectory: project, label: "other", root: root, store: store)

        let prefix = String(created.context.header.id.uuidString.prefix(8)).lowercased()
        let match = try SessionManager.findSession(matching: prefix, for: project, root: root, store: store)

        #expect(match?.context.header.id == created.context.header.id)
        #expect(match?.context.header.label == "target")
    }

    @Test("returns nil for unknown token")
    func missingSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = URL(fileURLWithPath: "/tmp/new-pi-missing-test")

        let match = try SessionManager.findSession(
            matching: "deadbeef",
            for: project,
            root: root
        )
        #expect(match == nil)
    }
}

@Suite("SessionCLIDisplay")
struct SessionCLIDisplayTests {
    @Test("formats empty session list")
    func emptyList() {
        let project = URL(fileURLWithPath: "/tmp/project")
        let output = SessionCLIDisplay.formatList([], projectURL: project)
        #expect(output.contains("(no sessions)"))
        #expect(output.contains("/tmp/project"))
    }

    @Test("formats session show output")
    func showOutput() {
        let header = SessionHeader(
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            providerProfileID: "deepseek",
            modelID: "deepseek-chat",
            label: "CLI test"
        )
        let context = SessionManager.rebuildContext(from: [.user("hello")], header: header)
        let fileURL = URL(fileURLWithPath: "/tmp/session.jsonl")
        let output = SessionCLIDisplay.formatShow(
            context: context,
            messages: SessionManager.messages(from: context),
            fileURL: fileURL
        )

        #expect(output.contains("CLI test"))
        #expect(output.contains("deepseek-chat"))
        #expect(output.contains("user: hello"))
    }
}
