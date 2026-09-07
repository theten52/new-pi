import Foundation
import Testing
@testable import NewPiCore

/// PROJECT-SCOPE-AUTO-APPROVE 端到端：走完整 AgentLoop 审批管线。
@Suite("ProjectScopeApprovalIntegration")
struct ProjectScopeApprovalIntegrationTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-scope-e2e-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeConfig(root: URL, auditURL: URL, llm: MockLLMProviderBox) -> AgentLoopConfig {
        AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: BuiltInTools.codingTools(for: root),
            toolPolicy: .codingAgentDefault,
            projectScope: ProjectScopePolicy(
                root: root,
                isEnabled: true,
                // 测试机的临时目录在 /private/var/folders 深处（不受限），home
                // 指到无关路径以保证判定与环境无关。
                homeDirectory: URL(fileURLWithPath: "/Users/tester/somewhere/project")
            ),
            auditLogger: ToolApprovalAuditLogger(fileURL: auditURL)
        )
    }

    @Test("in-root rm executes without approval prompt")
    func inRootRmAutoApproved() async throws {
        let root = try makeRoot()
        let target = root.appendingPathComponent("build.log")
        try Data("x".utf8).write(to: target)

        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "bash", arguments: .object(["command": .string("rm build.log")]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("cleaned"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("clean build artifacts"),
            context: AgentContext(systemPrompt: "test", workingDirectory: root),
            config: makeConfig(root: root, auditURL: auditURL, llm: llm)
        )

        // 未弹审批、文件确实被删（真实执行）。
        #expect(!events.contains { if case .toolApprovalRequired = $0 { true } else { false } })
        #expect(!FileManager.default.fileExists(atPath: target.path))

        // 审计记录授权来源为 project-scoped。
        let auditText = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(auditText.contains("project-scoped"))
        #expect(!auditText.contains("prompted"))
    }

    @Test("high-risk rm still prompts and denied call does not execute")
    func highRiskStillPrompts() async throws {
        let root = try makeRoot()
        let target = root.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: target)

        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "bash", arguments: .object(["command": .string("sudo rm keep.txt")]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("denied"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")

        var config = makeConfig(root: root, auditURL: auditURL, llm: llm)
        config.requestToolApproval = { _ in .deny }
        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("clean"),
            context: AgentContext(systemPrompt: "test", workingDirectory: root),
            config: config
        )

        // 高危（sudo）不被项目策略豁免：弹审批、拒绝后文件仍在。
        #expect(events.contains { if case .toolApprovalRequired = $0 { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: target.path))

        let auditText = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(auditText.contains("prompted"))
        #expect(!auditText.contains("project-scoped"))
    }
}
