import Foundation
import Testing
@testable import NewPiCore

@Suite("BuiltInTools")
struct BuiltInToolsTests {
    private func makeTempProject() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-pi-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("read returns numbered lines")
    func readFile() async throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let file = project.appendingPathComponent("hello.txt")
        try "alpha\nbeta".write(to: file, atomically: true, encoding: .utf8)

        let tool = ReadTool()
        let context = ToolContext(workingDirectory: project)
        let result = try await tool.execute(
            id: "1",
            arguments: .object(["path": .string("hello.txt")]),
            context: context,
            onUpdate: nil
        )

        #expect(result.content.contains("1|alpha"))
        #expect(result.content.contains("2|beta"))
    }

    @Test("write creates a file")
    func writeFile() async throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let tool = WriteTool()
        let context = ToolContext(workingDirectory: project)
        _ = try await tool.execute(
            id: "1",
            arguments: .object([
                "path": .string("nested/out.txt"),
                "content": .string("hello new-pi"),
            ]),
            context: context,
            onUpdate: nil
        )

        let written = project.appendingPathComponent("nested/out.txt")
        let text = try String(contentsOf: written, encoding: .utf8)
        #expect(text == "hello new-pi")
    }

    @Test("edit replaces a unique string and snapshots")
    func editFile() async throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let file = project.appendingPathComponent("sample.swift")
        try "let value = 1".write(to: file, atomically: true, encoding: .utf8)

        let tool = EditTool(snapshotStore: .forProject(project))
        let context = ToolContext(workingDirectory: project)
        _ = try await tool.execute(
            id: "1",
            arguments: .object([
                "path": .string("sample.swift"),
                "old_string": .string("let value = 1"),
                "new_string": .string("let value = 2"),
            ]),
            context: context,
            onUpdate: nil
        )

        let updated = try String(contentsOf: file, encoding: .utf8)
        #expect(updated == "let value = 2")

        let snapshots = project.appendingPathComponent(".new-pi/snapshots")
        let files = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        #expect(!files.isEmpty)
    }

    @Test("bash runs a command in project cwd")
    func bashCommand() async throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        let tool = BashTool(timeoutSeconds: 5)
        let context = ToolContext(workingDirectory: project)
        let result = try await tool.execute(
            id: "1",
            arguments: .object(["command": .string("pwd")]),
            context: context,
            onUpdate: nil
        )

        #expect(result.content.contains(project.path))
        #expect(result.content.contains("[exit 0]"))
    }

    @Test("path resolver blocks escaping workspace")
    func pathEscapeBlocked() throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project) }

        #expect(throws: PathResolverError.self) {
            _ = try PathResolver.resolve("../../etc/passwd", relativeTo: project)
        }
    }
}

@Suite("ToolApproval")
struct ToolApprovalTests {
    @Test("approval gate resolves allow and deny")
    func gateAllowDeny() async {
        let gate = ToolApprovalGate()

        let waitTask = Task {
            await gate.wait(for: "call-1")
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        await gate.respond(requestID: "call-1", approved: true)
        let approved = await waitTask.value
        #expect(approved)

        let denyTask = Task {
            await gate.wait(for: "call-2")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await gate.respond(requestID: "call-2", approved: false)
        let denied = await denyTask.value
        #expect(!denied)
    }

    @Test("tool policy requires approval for risky tools only")
    func policyRules() {
        let rules = ToolPolicyRules.codingAgentDefault
        #expect(!rules.requiresApproval(toolName: "read"))
        #expect(rules.requiresApproval(toolName: "bash"))
        #expect(rules.requiresApproval(toolName: "write"))
    }
}
