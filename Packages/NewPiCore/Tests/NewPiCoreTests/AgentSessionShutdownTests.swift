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
}
