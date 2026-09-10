import Foundation
import Testing
@testable import NewPiCore

@Suite("ChatRoom authorization isolation")
@MainActor
struct ChatRoomAuthorizationTests {
    private func request(_ tool: String = "bash", risk: ToolDangerLevel = .medium, command: String = "swift test") -> ToolApprovalRequest {
        ToolApprovalRequest(id: UUID().uuidString, toolName: tool,
            arguments: .object(["command": .string(command)]), summary: command,
            dangerLevel: risk, dangerReason: "test risk reason")
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate(), "approval state timed out")
        throw Timeout()
    }
    private struct Timeout: Error {}

    private func grant(_ manager: ChatRoomApprovalManager, request: ToolApprovalRequest, scope: ApprovalScope) async throws -> ApprovalDecision {
        let task = Task { await manager.approvalDecision(for: request, roleID: "role-a", roleName: "Role A") }
        defer { task.cancel() }
        try await wait { !manager.pendingApprovals.isEmpty }
        let pending = try #require(manager.pendingApprovals.first)
        #expect(pending.request.dangerLevel == request.dangerLevel)
        #expect(pending.request.dangerReason == request.dangerReason)
        #expect(pending.request.parametersFingerprint == request.parametersFingerprint)
        manager.approve(id: pending.id, scope: scope)
        return await task.value
    }

    @Test("once still prompts again; session scope covers different arguments and roles")
    func scopes() async throws {
        let manager = ChatRoomApprovalManager()
        #expect(try await grant(manager, request: request(), scope: .once) == .allowOnce)
        #expect(!manager.hasRememberedApprovals)
        #expect(try await grant(manager, request: request(), scope: .session) == .allowSession)
        var automatic: ApprovalDecision?
        let task = Task {
            automatic = await manager.approvalDecision(for: request(command: "swift build"), roleID: "role-b", roleName: "Role B")
        }
        defer { task.cancel() }
        try await wait { automatic != nil }
        #expect(automatic?.approved == true && manager.pendingApprovals.isEmpty)
        #expect(manager.hasRememberedApprovals)
        #expect(await manager.tracker.isAuthorized(toolName: "write", fingerprint: "different-tool", dangerLevel: .medium) == false)
    }

    @Test("room grants do not cover other rooms or a recreated manager")
    func independentRooms() async throws {
        let first = ChatRoomApprovalManager(), second = ChatRoomApprovalManager()
        _ = try await grant(first, request: request(), scope: .session)
        #expect(await first.tracker.isAuthorized(toolName: "bash", fingerprint: "x", dangerLevel: .medium))
        #expect(await second.tracker.isAuthorized(toolName: "bash", fingerprint: "x", dangerLevel: .medium) == false)
        #expect(await ChatRoomApprovalManager().tracker.isAuthorized(toolName: "bash", fingerprint: "x", dangerLevel: .medium) == false)
    }

    @Test("global permanent record does not enter memory-only tracker, which rejects forever writes")
    func persistentIsolation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let disk = PersistentApprovalStore(fileURL: file)
        let session = ToolApprovalTracker(persistentStore: disk)
        await session.record(scope: .forever, toolName: "bash", fingerprint: "x", dangerLevel: .medium)
        let before = try Data(contentsOf: file)
        let room = ChatRoomApprovalManager()
        #expect(await room.tracker.isAuthorized(toolName: "bash", fingerprint: "x", dangerLevel: .medium) == false)
        await room.tracker.record(scope: .forever, toolName: "write", fingerprint: "x", dangerLevel: .medium)
        #expect(await room.tracker.isAuthorized(toolName: "write", fingerprint: "x", dangerLevel: .medium) == false)
        _ = try await grant(room, request: request("edit"), scope: .session)
        #expect(try Data(contentsOf: file) == before)
        #expect(await session.isAuthorized(toolName: "edit", fingerprint: "x", dangerLevel: .medium) == false)
    }

    @Test("high risk always prompts and cannot be remembered even when API requests session or forever")
    func highRisk() async throws {
        let manager = ChatRoomApprovalManager()
        _ = try await grant(manager, request: request(), scope: .session)
        #expect(try await grant(manager, request: request(risk: .high), scope: .session) == .allowOnce)
        #expect(try await grant(manager, request: request(risk: .high), scope: .forever) == .allowOnce)
        #expect(await manager.tracker.isAuthorized(toolName: "bash", fingerprint: "x", dangerLevel: .high) == false)
        let fresh = ChatRoomApprovalManager()
        #expect(try await grant(fresh, request: request(), scope: .forever) == .allowOnce)
        #expect(!fresh.hasRememberedApprovals)
    }

    @Test("clear removes grants and restores prompts")
    func clear() async throws {
        let manager = ChatRoomApprovalManager()
        _ = try await grant(manager, request: request(), scope: .session)
        await manager.clearRememberedApprovals()
        #expect(!manager.hasRememberedApprovals)
        #expect(await manager.tracker.isAuthorized(toolName: "bash", fingerprint: "x", dangerLevel: .medium) == false)
        #expect(try await grant(manager, request: request(), scope: .once) == .allowOnce)
    }

    @Test("deny, cancellation and late clicks never leave grants or stuck pending requests")
    func cancelledAndDenied() async throws {
        let manager = ChatRoomApprovalManager()
        for cancel in [false, true] {
            let task = Task { await manager.approvalDecision(for: request(), roleID: "role", roleName: "Role") }
            defer { task.cancel() }
            try await wait { !manager.pendingApprovals.isEmpty }
            let id = manager.pendingApprovals[0].id
            if cancel { task.cancel() } else { manager.reject(id: id) }
            #expect(await task.value == .deny)
            try await wait { manager.pendingApprovals.isEmpty }
            manager.approve(id: id, scope: .session)
            #expect(!manager.hasRememberedApprovals)
            #expect(await manager.tracker.isAuthorized(toolName: "bash", fingerprint: "x", dangerLevel: .medium) == false)
        }
        let alreadyCancelled = Task { () -> ApprovalDecision in
            withUnsafeCurrentTask { $0?.cancel() }
            return await manager.approvalDecision(for: request(), roleID: "role", roleName: "Role")
        }
        #expect(await alreadyCancelled.value == .deny)
        #expect(manager.pendingApprovals.isEmpty)
    }

    @Test("queued same-tool requests covered together, high risk and different tools stay pending")
    func queue() async throws {
        let manager = ChatRoomApprovalManager()
        let requests = [request(), request(), request(risk: .high), request("write")]
        let tasks = requests.map { req in Task { await manager.approvalDecision(for: req, roleID: "role", roleName: "Role") } }
        defer { tasks.forEach { $0.cancel() } }
        try await wait { manager.pendingApprovals.count == 4 }
        let id = try #require(manager.pendingApprovals.first { $0.toolCall.id == requests[0].id }?.id)
        manager.approve(id: id, scope: .session)
        #expect(await tasks[0].value == .allowSession)
        #expect(await tasks[1].value == .allowSession)
        #expect(manager.pendingApprovals.count == 2)
        for pending in manager.pendingApprovals { manager.reject(id: pending.id) }
        #expect(await tasks[2].value == .deny)
        #expect(await tasks[3].value == .deny)
    }

    @Test("legacy writes use canonical tool memory and retain rejection reason")
    func legacy() async throws {
        let policy = ApprovalPolicyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let manager = ChatRoomApprovalManager(policyStore: policy)
        _ = try await grant(manager, request: request("write"), scope: .session)
        var approved = false
        let task = Task {
            let result = await manager.requestApproval(toolCall: ToolCallContent(id: "legacy", name: "write_file",
                arguments: .object(["path": .string("src/file.swift"), "content": .string("text")])), roleID: "other", roleName: "Other")
            if case .approved = result { approved = true }
        }
        defer { task.cancel() }
        try await wait { approved }
        await manager.clearRememberedApprovals()
        let denied = Task { await manager.requestApproval(toolCall: ToolCallContent(id: "denied", name: "write_file",
            arguments: .object(["path": .string("src/file.swift")])), roleID: "role", roleName: "Role") }
        defer { denied.cancel() }
        try await wait { !manager.pendingApprovals.isEmpty }
        manager.reject(id: manager.pendingApprovals[0].id, reason: "custom reason")
        if case .rejected(let reason) = await denied.value { #expect(reason == "custom reason") }
        else { Issue.record("legacy rejection expected") }
    }

    private actor ToolCounter {
        var count = 0
        func record() { count += 1 }
    }
    private struct FakeMCPTool: AgentTool {
        let counter: ToolCounter
        var name: String { "mcp/test/build" }
        var definition: ToolDefinition { ToolDefinition(name: name, description: "No-op test tool", parameters: .object([:])) }
        func execute(id: String, arguments: JSONValue, context: ToolContext,
            onUpdate: (@Sendable (ToolProgress) -> Void)?) async throws -> ToolResult {
            await counter.record()
            return ToolResult(content: "test tool complete")
        }
    }

    @Test("real chatroom loop shares grants across role speeches, audits source and resets")
    func engineIntegration() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let policyStore = ApprovalPolicyStore(fileURL: dir.appendingPathComponent("policy.json"))
        try policyStore.save(ApprovalPolicy(riskRules: [], toolBaseline: ["mcp/test/build": .medium]))
        let manager = ChatRoomApprovalManager(policyStore: policyStore)
        let counter = ToolCounter()
        let roles = ["A", "B"].map { ChatRoomRole(name: $0, description: "", systemPrompt: "", providerProfileID: "mock", modelID: "mock") }
        let room = ChatRoom(name: "test", roles: roles, projectPath: dir.path)
        let disk = ChatRoomStore(baseDirectory: dir.appendingPathComponent("rooms"))
        try disk.save(room)
        let runtime = ChatRoomRuntime(chatroom: room)
        let scripts: [[LLMStreamEvent]] = (0..<4).flatMap { index in
            [
                [.toolCall(ToolCallContent(id: "call-\(index)", name: "mcp/test/build", arguments: .object(["index": .string(String(index))]))),
                 .completed(stopReason: .toolUse, usage: UsageStats())],
                [.textDelta("done"), .completed(stopReason: .stop, usage: UsageStats())]
            ]
        }
        let llm = MockLLMProviderBox(scripts: scripts)
        let auditURL = dir.appendingPathComponent("audit.jsonl")
        let loop = ChatRoomLoop(store: disk, approvalManager: manager, engineProvider: { _ in
            ChatRoomRoleEngine(llm: llm, model: ModelConfig(provider: "mock", modelID: "mock"))
        }, mcpToolsProvider: { [FakeMCPTool(counter: counter)] }, auditLogger: ToolApprovalAuditLogger(fileURL: auditURL))
        for index in 0..<4 {
            if index == 2 { await manager.clearRememberedApprovals() }
            if index == 3 {
                // 用户修改保存的危险规则后，下轮必须重新评估，不能被旧中风险授权覆盖。
                try policyStore.save(ApprovalPolicy(riskRules: [ApprovalRiskRule(pattern: "index", reason: "custom high risk")]))
            }
            var completed = false
            let task = Task {
                try await loop.triggerSpeaker(roleID: roles[index % 2].id, runtime: runtime)
                completed = true
            }
            defer { task.cancel() }
            if index != 1 {
                try await wait { !manager.pendingApprovals.isEmpty }
                let approval = try #require(manager.pendingApprovals.first)
                #expect(approval.roleID == roles[index % 2].id)
                if index == 3 {
                    #expect(approval.dangerLevel == .high)
                    #expect(approval.dangerReason?.contains("custom high risk") == true)
                }
                manager.approve(id: approval.id, scope: .session)
            }
            try await wait { completed }
            try await task.value
            #expect(manager.pendingApprovals.isEmpty)
        }
        #expect(await counter.count == 4)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let audit = try String(contentsOf: auditURL, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(ToolApprovalAuditEntry.self, from: Data($0.utf8))
        }
        #expect(audit.map(\.authorization) == [.prompted, .sessionRecord, .prompted, .prompted])
        #expect(audit.last?.decisionScope == .once)
        #expect(audit.allSatisfy { $0.workingDirectory == dir.path })
    }
}
