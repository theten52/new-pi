import Foundation
import Testing
@testable import NewPiCore

/// 一个"生成到一半会阻塞"的 LLM provider：先吐出两条 textDelta，然后让测试端
/// 收到"已经开始生成"的信号，之后一直挂起，直到 run 被取消。用来确定性地测试
/// 流式未完成时 `shutdown()`（用户切换 session）的行为。
struct GatedLLMProvider: LLMProvider {
    let gate: StreamGate

    init(gate: StreamGate) {
        self.gate = gate
    }

    func stream(
        model: ModelConfig,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta("Hello "))
                    continuation.yield(.textDelta("there"))
                    await gate.markStarted()
                    // 模拟一个很长的生成；测试端会在此时取消 run。
                    try await Task.sleep(for: .seconds(3600))
                    continuation.yield(.completed(stopReason: .stop, usage: UsageStats(inputTokens: 1, outputTokens: 2)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// 让测试端等待 generator 真正进入流式中段。
actor StreamGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@Suite("AgentSessionShutdown")
struct AgentSessionShutdownTests {

    @Test("shutdown during a streaming run stops it and persists the partial assistant text")
    func shutdownPersistsPartialOutput() async throws {
        let gate = StreamGate()
        let llm = GatedLLMProvider(gate: gate)
        let model = ModelConfig(provider: "gated", modelID: "gated-m")

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("newpi-shutdown-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let (created, fileURL) = try SessionManager.createSession(
            workingDirectory: workingDirectory,
            root: workingDirectory.appendingPathComponent(".new-pi", isDirectory: true)
        )

        let config = AgentLoopConfig(model: model, llm: llm)
        let context = AgentContext(systemPrompt: "test", workingDirectory: workingDirectory)
        let session = AgentSession(context: context, config: config)
        await session.attachPersistence(fileURL: fileURL, header: created.header)

        // 启动一个流式 run，等待它进入"已生成部分文本"阶段。
        await session.prompt(.user("say hi"))
        await gate.wait()

        // 模拟用户在生成途中切换 session：shutdown 应取消 run 并把已生成的部分落盘。
        await session.shutdown()

        let stored = try JSONLSessionStore().load(from: fileURL)
        let assistantTexts = SessionManager.messages(from: stored).compactMap { message -> String? in
            if case let .assistant(assistant) = message { return assistant.text }
            return nil
        }
        #expect(assistantTexts.contains("Hello there"))

        let messages = SessionManager.messages(from: stored)
        #expect(messages.contains { message in
            if case let .assistant(assistant) = message { return assistant.stopReason == .aborted }
            return false
        })
    }

    @Test("re-prompt clears pending approval and the cancelled run's tool never executes")
    func rePromptClearsPendingApproval() async throws {
        // 回归：prompt() 之前只取消 runTask，不清理审批门——旧 run 挂起在
        // 审批上，用户之后点"允许"会让已取消的 run 复活并真正执行工具。
        let counter = ToolExecutionCounter()
        let approvalArrived = StreamGate()

        let llm = MockLLMProviderBox(scripts: [
            [
                .toolCall(ToolCallContent(id: "call_1", name: "count", arguments: .object([:]))),
                .completed(stopReason: .toolUse, usage: UsageStats()),
            ],
            [
                .textDelta("done"),
                .completed(stopReason: .stop, usage: UsageStats()),
            ],
        ])

        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            tools: [CountingTool(counter: counter)],
            toolPolicy: ToolPolicyRules(requireApprovalFor: ["count"])
        )
        let session = AgentSession(
            context: AgentContext(systemPrompt: "test"),
            config: config
        )

        // 监听事件流：第一个 run 的审批请求出现时放行测试主线。
        let eventStream = await session.events()
        let collector = Task {
            for await event in eventStream {
                if case .toolApprovalRequired = event {
                    await approvalArrived.markStarted()
                }
            }
        }

        await session.prompt(.user("run count"))
        await approvalArrived.wait()

        // 旧 run 正挂起在审批门。直接发新 prompt（用户不等审批继续提问）。
        await session.prompt(.user("again"))

        // 新 prompt 之后，旧审批请求必须已被清理：再响应它应当是 no-op。
        await session.respondToToolApproval(requestID: "call_1", approved: true)
        #expect(await counter.count == 0)

        // 等第二个 run 完成。
        let finished = await waitUntilTrue {
            await session.context.messages.contains { message in
                if case let .assistant(assistant) = message { return assistant.text == "done" }
                return false
            }
        }
        #expect(finished)
        #expect(await counter.count == 0)

        collector.cancel()
        await session.shutdown()
    }
}

private actor ToolExecutionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct CountingTool: AgentTool {
    let counter: ToolExecutionCounter
    let name = "count"
    let definition = ToolDefinition(
        name: "count",
        description: "Counts executions",
        parameters: .object([:])
    )

    func execute(
        id: String,
        arguments: JSONValue,
        context: ToolContext,
        onUpdate: (@Sendable (ToolProgress) -> Void)?
    ) async throws -> ToolResult {
        await counter.increment()
        return ToolResult(content: "ok")
    }
}

/// 轮询直到条件成立或超时（用于等待异步 run 收尾）。
private func waitUntilTrue(
    timeout: Duration = .seconds(2),
    _ check: @escaping () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await check()
}
