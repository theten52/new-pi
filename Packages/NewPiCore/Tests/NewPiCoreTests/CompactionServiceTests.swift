import Foundation
import Testing
@testable import NewPiCore

@Suite("ContextTokenEstimator")
struct ContextTokenEstimatorTests {
    @Test("estimates longer messages higher")
    func longerMessagesCostMore() {
        let short = ContextTokenEstimator.estimate(.user("hi"))
        let long = ContextTokenEstimator.estimate(.user(String(repeating: "a", count: 400)))
        #expect(long > short)
    }

    @Test("CJK text is weighted ~1 token per character, ASCII ~4 characters per token")
    func cjkWeightedEstimation() {
        // 200 个汉字 ≈ 200 token；旧实现（count/4）会低估成 50
        let cjk = ContextTokenEstimator.estimate(text: String(repeating: "你好", count: 100))
        #expect(cjk >= 190 && cjk <= 210)

        // 400 个 ASCII 字符 ≈ 100 token
        let ascii = ContextTokenEstimator.estimate(text: String(repeating: "a", count: 400))
        #expect(ascii >= 95 && ascii <= 105)
    }
}

@Suite("CompactionConfig")
struct CompactionConfigTests {
    @Test("recommended budget derives from model context window")
    func recommendedBudget() {
        let config = CompactionConfig.recommended(contextWindow: 200_000)
        #expect(config.contextTokenLimit == 160_000)
        #expect(config.triggerTokenCount == 120_000)

        // 小窗口模型预算同步收窄，避免压缩触发太晚
        let small = CompactionConfig.recommended(contextWindow: 32_000)
        #expect(small.contextTokenLimit == 25_600)
    }
}

@Suite("CompactionService partition")
struct CompactionPartitionTests {
    @Test("keeps recent messages and avoids splitting tool results")
    func partitionRespectsToolPairs() {
        let messages: [AgentMessage] = [
            .user("one"),
            .assistant(AssistantMessage(
                text: "calling tool",
                toolCalls: [ToolCallContent(id: "1", name: "echo", arguments: .object(["text": .string("x")]))],
                provider: "mock",
                modelID: "m",
                stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(toolCallID: "1", toolName: "echo", content: "x", isError: false)),
            .user("two"),
            .user("three"),
        ]

        let result = CompactionService.partition(messages: messages, keepRecent: 2)
        #expect(result != nil)
        let (toCompact, toKeep) = result!
        #expect(toCompact.count == 3)
        #expect(toKeep.count == 2)
        if case .user = toKeep.first {} else {
            Issue.record("Expected first kept message to be user")
        }
    }
}

@Suite("CompactionService integration")
struct CompactionServiceIntegrationTests {
    @Test("compacts history when token threshold exceeded")
    func compactsOnThreshold() async {
        let longHistory = (0..<12).map { index in
            AgentMessage.user(String(repeating: "word\(index) ", count: 80))
        }
        var context = AgentContext(systemPrompt: "system", messages: longHistory)

        let llm = MockLLMProviderBox(scripts: [
            [.textDelta("Summary of prior work."), .completed(stopReason: .stop, usage: UsageStats())],
            [.textDelta("Done."), .completed(stopReason: .stop, usage: UsageStats())],
        ])
        let config = AgentLoopConfig(
            model: AgentLoopTestSupport.defaultModel,
            llm: llm,
            compaction: CompactionConfig(
                enabled: true,
                contextTokenLimit: 500,
                triggerRatio: 0.5,
                keepRecentMessages: 2
            )
        )

        let events = await AgentLoopTestSupport.collectEvents(
            prompt: .user("continue"),
            context: context,
            config: config
        )

        if let snapshot = events.compactMap({
            if case let .contextSnapshot(ctx) = $0 { ctx } else { nil }
        }).last {
            context = snapshot
        }

        #expect(context.messages.count <= 4)
        if case let .compactionSummary(summary) = context.messages.first {
            #expect(summary.contains("Summary"))
        } else {
            Issue.record("Expected compaction summary as first message")
        }
    }
}

@Suite("SessionManager compaction entries")
struct SessionManagerCompactionTests {
    @Test("round-trips compaction summary entries")
    func compactionRoundTrip() throws {
        let header = SessionHeader(workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        let messages: [AgentMessage] = [
            .compactionSummary("Earlier discussion about auth."),
            .user("What's next?"),
        ]
        let context = SessionManager.rebuildContext(from: messages, header: header)

        let entryTypes = context.entries.map(\.type)
        #expect(entryTypes == [.compaction, .message])

        let restored = SessionManager.messages(from: context)
        #expect(restored.count == 2)
        if case let .compactionSummary(summary) = restored[0] {
            #expect(summary.contains("auth"))
        } else {
            Issue.record("Expected compaction summary message")
        }
    }
}
