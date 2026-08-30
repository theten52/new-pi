import Foundation
import Testing
@testable import NewPiCore

/// 审批审计日志：JSONL 持久化、轮转、参数截断、AgentLoop 集成（审批路径/用户决定）。
struct ToolApprovalAuditLogTests {

    private func makeIsolatedLogger(maxFileSize: Int = 10 * 1024 * 1024) -> ToolApprovalAuditLogger {
        ToolApprovalAuditLogger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-audit-\(UUID().uuidString).jsonl"),
            maxFileSize: maxFileSize
        )
    }

    private func makeEntry(
        toolName: String = "bash",
        authorization: ToolApprovalAuditEntry.Authorization = .prompted,
        decisionApproved: Bool? = true,
        decisionScope: ApprovalScope? = .once
    ) -> ToolApprovalAuditEntry {
        ToolApprovalAuditEntry(
            workingDirectory: "/tmp",
            callID: "call_1",
            toolName: toolName,
            arguments: #"{"command":"ls"}"#,
            argumentsTruncated: false,
            summary: "Run command:\nls",
            fingerprint: "abc",
            dangerLevel: .medium,
            dangerReason: "可能修改文件或执行命令，需确认",
            matchedRules: [],
            policyRequiresApproval: true,
            approvalPrompted: authorization == .prompted,
            authorization: authorization,
            decisionApproved: decisionApproved,
            decisionScope: decisionScope
        )
    }

    private func readEntries(_ logger: ToolApprovalAuditLogger, fileURL: URL) throws -> [ToolApprovalAuditEntry] {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { try? decoder.decode(ToolApprovalAuditEntry.self, from: Data($0.utf8)) } ?? []
    }

    @Test func entriesAppendAsJSONL() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audit-\(UUID().uuidString).jsonl")
        let logger = ToolApprovalAuditLogger(fileURL: fileURL)
        logger.record(makeEntry())
        logger.record(makeEntry(toolName: "write", authorization: .lowRisk, decisionApproved: nil, decisionScope: nil))

        let entries = try readEntries(logger, fileURL: fileURL)
        #expect(entries.count == 2)
        #expect(entries[0].toolName == "bash")
        #expect(entries[0].authorization == .prompted)
        #expect(entries[0].decisionScope == .once)
        #expect(entries[1].authorization == .lowRisk)
        #expect(entries[1].decisionApproved == nil)
    }

    @Test func rotatesWhenFileTooLarge() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audit-\(UUID().uuidString).jsonl")
        let logger = ToolApprovalAuditLogger(fileURL: fileURL, maxFileSize: 100)
        for _ in 0..<5 {
            logger.record(makeEntry())
        }
        let rotated = fileURL.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension(fileURL.pathExtension)
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func serializeArgumentsTruncatesLongValues() {
        let big = String(repeating: "x", count: ToolApprovalAuditLogger.maxArgumentsLength * 2)
        let (text, truncated) = ToolApprovalAuditLogger.serializeArguments(
            .object(["content": .string(big)])
        )
        #expect(truncated)
        #expect(text.count == ToolApprovalAuditLogger.maxArgumentsLength)

        let (small, smallTruncated) = ToolApprovalAuditLogger.serializeArguments(
            .object(["command": .string("ls")])
        )
        #expect(!smallTruncated)
        #expect(small.contains("ls"))
    }

    // MARK: - AgentLoop 集成

    /// 假 bash：不真正执行命令，仅返回成功。
    struct FakeBashTool: AgentTool {
        let name = "bash"
        let definition = ToolDefinition(
            name: "bash",
            description: "fake bash",
            parameters: .object(["command": .string("")])
        )

        func execute(
            id: String,
            arguments: JSONValue,
            context: ToolContext,
            onUpdate: (@Sendable (ToolProgress) -> Void)?
        ) async throws -> ToolResult {
            ToolResult(content: "ok")
        }
    }

    private actor ApprovalCallCounter {
        var count = 0
        func increment() { count += 1 }
    }

    private func makeConfig(
        scripts: [[LLMStreamEvent]],
        auditLogger: ToolApprovalAuditLogger,
        approvalCounter: ApprovalCallCounter,
        tracker: ToolApprovalTracker
    ) -> AgentLoopConfig {
        AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: MockLLMProviderBox(scripts: scripts),
            tools: [FakeBashTool(), EchoTool()],
            toolPolicy: .codingAgentDefault,
            requestToolApproval: { _ in
                await approvalCounter.increment()
                return .allowSession
            },
            toolApprovalTracker: tracker,
            auditLogger: auditLogger
        )
    }

    private func isolatedTracker() -> ToolApprovalTracker {
        ToolApprovalTracker(
            persistentStore: PersistentApprovalStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("test-approvals-\(UUID().uuidString).json")
            )
        )
    }

    @Test func auditRecordsPromptedDecision() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audit-\(UUID().uuidString).jsonl")
        let logger = ToolApprovalAuditLogger(fileURL: fileURL)
        let counter = ApprovalCallCounter()
        let config = makeConfig(
            scripts: [[
                .toolCall(ToolCallContent(
                    id: "call_1",
                    name: "bash",
                    arguments: .object(["command": .string("mkdir -p build")])
                )),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ]],
            auditLogger: logger,
            approvalCounter: counter,
            tracker: isolatedTracker()
        )
        _ = await AgentLoopTestSupport.collectEvents(
            prompt: .user("run"),
            context: AgentContext(systemPrompt: "s", workingDirectory: URL(fileURLWithPath: "/tmp")),
            config: config
        )

        let entries = try readEntries(logger, fileURL: fileURL)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.toolName == "bash")
        #expect(entry.arguments.contains("mkdir -p build"))
        #expect(entry.policyRequiresApproval)
        #expect(entry.approvalPrompted)
        #expect(entry.authorization == .prompted)
        #expect(entry.dangerLevel == .medium)
        #expect(entry.decisionApproved == true)
        #expect(entry.decisionScope == .session)
        #expect(await counter.count == 1)
    }

    @Test func auditRecordsRememberedSessionAuthorization() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audit-\(UUID().uuidString).jsonl")
        let logger = ToolApprovalAuditLogger(fileURL: fileURL)
        let counter = ApprovalCallCounter()
        // 两个 turn 两次 bash：第一次弹窗（session 允许），第二次命中记忆直接放行。
        let config = makeConfig(
            scripts: [
                [
                    .toolCall(ToolCallContent(
                        id: "call_1",
                        name: "bash",
                        arguments: .object(["command": .string("mkdir -p a")])
                    )),
                    .completed(stopReason: .toolUse, usage: UsageStats()),
                ],
                [
                    .toolCall(ToolCallContent(
                        id: "call_2",
                        name: "bash",
                        arguments: .object(["command": .string("mkdir -p b")])
                    )),
                    .completed(stopReason: .toolUse, usage: UsageStats()),
                ],
            ],
            auditLogger: logger,
            approvalCounter: counter,
            tracker: isolatedTracker()
        )
        _ = await AgentLoopTestSupport.collectEvents(
            prompt: .user("run"),
            context: AgentContext(systemPrompt: "s", workingDirectory: URL(fileURLWithPath: "/tmp")),
            config: config
        )

        let entries = try readEntries(logger, fileURL: fileURL)
        #expect(entries.count == 2)
        #expect(entries[0].authorization == .prompted)
        #expect(entries[1].authorization == .sessionRecord)
        #expect(!entries[1].approvalPrompted)
        #expect(entries[1].decisionApproved == nil)
        #expect(await counter.count == 1)
    }

    @Test func auditRecordsLowRiskExemption() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audit-\(UUID().uuidString).jsonl")
        let logger = ToolApprovalAuditLogger(fileURL: fileURL)
        let counter = ApprovalCallCounter()
        let config = makeConfig(
            scripts: [[
                .toolCall(ToolCallContent(
                    id: "call_1",
                    name: "bash",
                    arguments: .object(["command": .string("ls -la | head -5")])
                )),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ]],
            auditLogger: logger,
            approvalCounter: counter,
            tracker: isolatedTracker()
        )
        _ = await AgentLoopTestSupport.collectEvents(
            prompt: .user("run"),
            context: AgentContext(systemPrompt: "s", workingDirectory: URL(fileURLWithPath: "/tmp")),
            config: config
        )

        let entries = try readEntries(logger, fileURL: fileURL)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.policyRequiresApproval)
        #expect(!entry.approvalPrompted)
        #expect(entry.authorization == .lowRisk)
        #expect(entry.dangerLevel == .low)
        // 只读命令未弹窗
        #expect(await counter.count == 0)
    }

    @Test func auditRecordsNotRequiredTool() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audit-\(UUID().uuidString).jsonl")
        let logger = ToolApprovalAuditLogger(fileURL: fileURL)
        let counter = ApprovalCallCounter()
        let config = makeConfig(
            scripts: [[
                .toolCall(ToolCallContent(
                    id: "call_1",
                    name: "echo",
                    arguments: .object(["text": .string("hello")])
                )),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ]],
            auditLogger: logger,
            approvalCounter: counter,
            tracker: isolatedTracker()
        )
        _ = await AgentLoopTestSupport.collectEvents(
            prompt: .user("run"),
            context: AgentContext(systemPrompt: "s", workingDirectory: URL(fileURLWithPath: "/tmp")),
            config: config
        )

        let entries = try readEntries(logger, fileURL: fileURL)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(!entry.policyRequiresApproval)
        #expect(entry.authorization == .notRequired)
        #expect(await counter.count == 0)
    }
}
